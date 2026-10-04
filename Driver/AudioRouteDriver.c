/* Original AudioServerPlugIn implementation using Apple's public HAL ABI.
 * Registry polling is control-plane; audio callbacks only touch immutable device
 * descriptions, atomics and pre-mapped SPSC audio rings. No third-party driver code. */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <pthread.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include "VirtualAudioTransport.h"
#define MAX_DEVICES 128
#define DEVICE_BASE 100
#define PERIOD 512
#ifdef AR_DRIVER_TEST
static const char *registryPath = AR_SHARED_DIRECTORY "/registry.plist";
#else
static xpc_connection_t broker;
static _Atomic bool registryRequestPending;
#endif
typedef struct {
    char id[128]; CFStringRef name, uid;
    uint32_t input, output; double rate;
    _Atomic bool alive; _Atomic uint32_t running;
    _Atomic uint64_t anchor, seed;
    ar_transport *transport;
    // HAL serializes a device's IO cycle operations on its IO thread. Cache is
    // addressed by sample time, so all clients get identical input, including
    // clients whose buffer lengths differ. Only IO touches this preallocated area.
    bool cacheValid, outputTimeValid;
    int64_t cacheOrigin, cacheEnd, outputEnd;
    float inputCache[AR_TRANSPORT_CAPACITY * AR_TRANSPORT_MAX_CHANNELS];
} Device;
static Device devices[MAX_DEVICES];
static _Atomic uint32_t deviceCount;
static AudioServerPlugInHostRef host;
static pthread_mutex_t controlLock = PTHREAD_MUTEX_INITIALIZER;
static double ticksPerSecond;
static uint32_t driverPID;
static _Atomic uint32_t refs = 1;
static dispatch_source_t registryTimer;
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePtr = &interface;
static AudioServerPlugInDriverRef driver = &interfacePtr;
static AudioObjectID deviceID(uint32_t index) { return DEVICE_BASE + index * 3; }
static Device *lookup(AudioObjectID object, int *kind) {
    if (object < DEVICE_BASE) return NULL;
    uint32_t index = (object - DEVICE_BASE) / 3;
    if (index >= atomic_load_explicit(&deviceCount, memory_order_acquire)) return NULL;
    *kind = (object - DEVICE_BASE) % 3;
    Device *d = &devices[index];
    if ((*kind == 1 && !d->input) || (*kind == 2 && !d->output)) return NULL;
    return d;
}
static uint32_t channels(Device *d, const AudioObjectPropertyAddress *a, int kind) {
    if (kind) return kind == 1 ? d->input : d->output;
    return a->mScope == kAudioObjectPropertyScopeInput ? d->input : a->mScope == kAudioObjectPropertyScopeOutput ? d->output : d->input + d->output;
}
static AudioStreamBasicDescription format(Device *d, uint32_t ch) {
    AudioStreamBasicDescription f = {0}; f.mSampleRate=d->rate; f.mFormatID=kAudioFormatLinearPCM;
    f.mFormatFlags=kAudioFormatFlagsNativeFloatPacked; f.mBytesPerPacket=ch*4; f.mFramesPerPacket=1;
    f.mBytesPerFrame=ch*4; f.mChannelsPerFrame=ch; f.mBitsPerChannel=32; return f;
}
static int validID(const char *s) {
    if (!s[0]) return 0;
    for (const char *p=s; *p; ++p) if (!((*p>='a'&&*p<='z')||(*p>='0'&&*p<='9')||*p=='-')) return 0;
    return 1;
}
static int number(CFDictionaryRef dict, CFStringRef key, int fallback) {
    CFTypeRef v=CFDictionaryGetValue(dict,key); int n=fallback;
    if (v&&CFGetTypeID(v)==CFNumberGetTypeID()) CFNumberGetValue(v,kCFNumberIntType,&n); return n;
}
static void notify(AudioObjectID object, AudioObjectPropertySelector selector) {
    if (host) { AudioObjectPropertyAddress a={selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain}; host->PropertiesChanged(host,object,1,&a); }
}
static void applyRegistry(CFDataRef data,xpc_object_t handles) {
    CFPropertyListRef plist=CFPropertyListCreateWithData(NULL,data,kCFPropertyListImmutable,NULL,NULL);
    if(!plist) return;
    CFArrayRef list=NULL;
    if(CFGetTypeID(plist)==CFDictionaryGetTypeID()) { CFTypeRef v=CFDictionaryGetValue(plist,CFSTR("devices"));if(v&&CFGetTypeID(v)==CFArrayGetTypeID())list=v; }
    if(!list){CFRelease(plist);return;}
    pthread_mutex_lock(&controlLock);
    bool seen[MAX_DEVICES]={0}, removed[MAX_DEVICES]={0}, changed=false;
    uint32_t count=atomic_load(&deviceCount);
    for(CFIndex j=0;j<CFArrayGetCount(list);++j) {
        CFTypeRef entry=CFArrayGetValueAtIndex(list,j);if(CFGetTypeID(entry)!=CFDictionaryGetTypeID())continue;
        CFTypeRef id=CFDictionaryGetValue(entry,CFSTR("id")),name=CFDictionaryGetValue(entry,CFSTR("name"));
        if(!id||!name||CFGetTypeID(id)!=CFStringGetTypeID()||CFGetTypeID(name)!=CFStringGetTypeID())continue;
        char identifier[128];if(!CFStringGetCString(id,identifier,sizeof(identifier),kCFStringEncodingUTF8)||!validID(identifier))continue;
        int input=number(entry,CFSTR("inputChannels"),0),output=number(entry,CFSTR("outputChannels"),0),rate=number(entry,CFSTR("sampleRate"),48000);
        if(input<0||output<0||input>32||output>32||!(input+output)||(rate!=44100&&rate!=48000&&rate!=96000))continue;
        uint32_t i=0;for(;i<count;++i)if(!strcmp(devices[i].id,identifier))break;
        if(i==count) {
            if(count==MAX_DEVICES)continue;
            ar_transport *t=NULL;
#ifdef AR_DRIVER_TEST
            char path[512];snprintf(path,sizeof(path),AR_SHARED_DIRECTORY "/devices/%s.shm",identifier);
            t=ar_transport_open(path,input,output,0);
#else
            if(handles&&xpc_get_type(handles)==XPC_TYPE_DICTIONARY)
                t=ar_transport_import_shared_memory(xpc_dictionary_get_value(handles,identifier),input,output);
#endif
            if(!t)continue;
            Device *d=&devices[i];strcpy(d->id,identifier);d->name=CFRetain(name);
            d->uid=CFStringCreateWithFormat(NULL,NULL,CFSTR("org.audioroute.virtual.%@"),id);
            d->input=input;d->output=output;d->rate=rate;d->transport=t;
            atomic_store(&d->anchor,mach_absolute_time());atomic_store(&d->seed,1);
            ar_transport_set_active_clients(t,0);
            ++count;atomic_store_explicit(&deviceCount,count,memory_order_release);changed=true;
        }
        Device *d=&devices[i];
        // A UID's channel layout and clock remain immutable; recreate with a new id to change them.
        if(d->input!=(uint32_t)input||d->output!=(uint32_t)output||d->rate!=rate)continue;
        seen[i]=true;if(!atomic_exchange(&d->alive,true))changed=true;
    }
    for(uint32_t i=0;i<count;++i)if(!seen[i]&&atomic_exchange(&devices[i].alive,false)){changed=true;removed[i]=true;}
    pthread_mutex_unlock(&controlLock);CFRelease(plist);
    for(uint32_t i=0;i<count;++i)if(removed[i])notify(deviceID(i),kAudioDevicePropertyDeviceIsAlive);
    if(changed){notify(kAudioObjectPlugInObject,kAudioPlugInPropertyDeviceList);notify(kAudioObjectPlugInObject,kAudioObjectPropertyOwnedObjects);}
}
static void refreshRegistry(void) {
#ifdef AR_DRIVER_TEST
    int fd=open(registryPath,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return;
    struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size>1024*1024||st.st_size<1){close(fd);return;}
    UInt8 *buffer=malloc(st.st_size);if(!buffer){close(fd);return;}
    ssize_t n=read(fd,buffer,st.st_size);close(fd);if(n!=st.st_size){free(buffer);return;}
    CFDataRef data=CFDataCreate(NULL,buffer,n);free(buffer);applyRegistry(data,NULL);CFRelease(data);
#else
    if(atomic_exchange(&registryRequestPending,true))return;
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);
    xpc_dictionary_set_string(message,"request","registry");
    xpc_connection_send_message_with_reply(broker,message,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^(xpc_object_t reply){
        if(xpc_get_type(reply)==XPC_TYPE_DICTIONARY){size_t length=0;const void *bytes=xpc_dictionary_get_data(reply,"registry",&length);
            if(bytes&&length&&length<=1024*1024){CFDataRef data=CFDataCreate(NULL,bytes,length);applyRegistry(data,xpc_dictionary_get_value(reply,"handles"));CFRelease(data);}
        }
        atomic_store(&registryRequestPending,false);
    });xpc_release(message);
#endif
}
static HRESULT query(void *self, REFIID uuid, LPVOID *out) {
    if(!out)return E_POINTER;*out=NULL;CFUUIDRef u=CFUUIDCreateFromUUIDBytes(NULL,uuid);
    bool match=CFEqual(u,IUnknownUUID)||CFEqual(u,kAudioServerPlugInDriverInterfaceUUID);CFRelease(u);
    if(!match)return E_NOINTERFACE;*out=driver;atomic_fetch_add(&refs,1);return S_OK;
}
static ULONG addRef(void *d){return atomic_fetch_add(&refs,1)+1;}
static ULONG releaseRef(void *d){uint32_t n=atomic_load(&refs);while(n>1&&!atomic_compare_exchange_weak(&refs,&n,n-1)){}return n>1?n-1:n;}
static OSStatus initialize(AudioServerPlugInDriverRef d,AudioServerPlugInHostRef h) {
    host=h;driverPID=getpid();mach_timebase_info_data_t time;mach_timebase_info(&time);ticksPerSecond=1e9*(double)time.denom/time.numer;
#ifndef AR_DRIVER_TEST
    broker=xpc_connection_create_mach_service("org.audioroute.transport",dispatch_get_global_queue(QOS_CLASS_UTILITY,0),XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if(!broker)return kAudioHardwareUnspecifiedError;
    xpc_connection_set_event_handler(broker,^(xpc_object_t error){atomic_store(&registryRequestPending,false);});xpc_connection_resume(broker);
#endif
    refreshRegistry();registryTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(registryTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,NSEC_PER_SEC/10);
    dispatch_source_set_event_handler(registryTimer,^{refreshRegistry();});dispatch_resume(registryTimer);return 0;
}
static OSStatus createDevice(AudioServerPlugInDriverRef d,CFDictionaryRef desc,const AudioServerPlugInClientInfo *c,AudioObjectID *out){return kAudioHardwareUnsupportedOperationError;}
static OSStatus destroyDevice(AudioServerPlugInDriverRef d,AudioObjectID id){return kAudioHardwareUnsupportedOperationError;}
static OSStatus client(AudioServerPlugInDriverRef d,AudioObjectID id,const AudioServerPlugInClientInfo *c){int k;return lookup(id,&k)&&!k?0:kAudioHardwareBadObjectError;}
static OSStatus configuration(AudioServerPlugInDriverRef d,AudioObjectID id,UInt64 a,void *i){return kAudioHardwareUnsupportedOperationError;}
static Boolean has(AudioServerPlugInDriverRef dr,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a) {
    if(!a)return false;
    int kind=0;Device *d=lookup(object,&kind);bool plugin=object==kAudioObjectPlugInObject;
    if(!plugin&&!d)return false;
    switch(a->mSelector) {
        case kAudioObjectPropertyBaseClass:case kAudioObjectPropertyClass:case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:case kAudioObjectPropertyManufacturer:case kAudioObjectPropertyOwnedObjects:return true;
    }
    if(plugin) return a->mSelector==kAudioPlugInPropertyDeviceList||a->mSelector==kAudioPlugInPropertyTranslateUIDToDevice||a->mSelector==kAudioPlugInPropertyResourceBundle;
    if(kind) switch(a->mSelector){
        case kAudioStreamPropertyIsActive:case kAudioStreamPropertyDirection:case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:case kAudioStreamPropertyLatency:case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:return true;default:return false;
    }
    switch(a->mSelector) {
        case kAudioDevicePropertyDeviceUID:case kAudioDevicePropertyModelUID:case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:case kAudioDevicePropertyClockDomain:case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:case kAudioDevicePropertyLatency:case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:case kAudioDevicePropertySafetyOffset:case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:case kAudioDevicePropertyClockAlgorithm:
        case kAudioDevicePropertyPreferredChannelsForStereo:case kAudioDevicePropertyPreferredChannelLayout:return true;
        default:return false;
    }
}
static OSStatus settable(AudioServerPlugInDriverRef d,AudioObjectID o,pid_t p,const AudioObjectPropertyAddress *a,Boolean *s){if(!s)return kAudioHardwareIllegalOperationError;if(!has(d,o,p,a))return kAudioHardwareUnknownPropertyError;*s=false;return 0;}
static uint32_t objectList(AudioObjectID object,const AudioObjectPropertyAddress *a,AudioObjectID *out) {
    uint32_t n=0,count=atomic_load(&deviceCount);int kind=0;Device *d=lookup(object,&kind);
    if(object==1){for(uint32_t i=0;i<count;++i)if(atomic_load(&devices[i].alive)){if(out)out[n]=deviceID(i);++n;}}
    else if(d&&!kind) { if(d->input&&a->mScope!=kAudioObjectPropertyScopeOutput){if(out)out[n]=object+1;++n;}if(d->output&&a->mScope!=kAudioObjectPropertyScopeInput){if(out)out[n]=object+2;++n;} }
    return n;
}
static OSStatus size(AudioServerPlugInDriverRef dr,AudioObjectID o,pid_t p,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 *out) {
    if(!out)return kAudioHardwareIllegalOperationError;if(!has(dr,o,p,a))return kAudioHardwareUnknownPropertyError;
    int kind=0;Device *d=lookup(o,&kind);
    switch(a->mSelector) {
        case kAudioObjectPropertyName:case kAudioObjectPropertyManufacturer:case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:case kAudioPlugInPropertyResourceBundle:*out=sizeof(CFStringRef);break;
        case kAudioObjectPropertyOwnedObjects:case kAudioPlugInPropertyDeviceList:case kAudioDevicePropertyStreams:*out=objectList(o,a,NULL)*sizeof(AudioObjectID);break;
        case kAudioDevicePropertyRelatedDevices:*out=sizeof(AudioObjectID);break;
        case kAudioObjectPropertyControlList:*out=0;break;
        case kAudioDevicePropertyNominalSampleRate:*out=sizeof(Float64);break;
        case kAudioDevicePropertyAvailableNominalSampleRates:*out=sizeof(AudioValueRange);break;
        case kAudioDevicePropertyPreferredChannelsForStereo:*out=2*sizeof(UInt32);break;
        case kAudioDevicePropertyPreferredChannelLayout:*out=offsetof(AudioChannelLayout,mChannelDescriptions)+channels(d,a,kind)*sizeof(AudioChannelDescription);break;
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:*out=sizeof(AudioStreamBasicDescription);break;
        case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:*out=sizeof(AudioStreamRangedDescription);break;
        default:*out=sizeof(UInt32);break;
    }return 0;
}
static OSStatus getUnlocked(AudioServerPlugInDriverRef dr,AudioObjectID o,pid_t p,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 capacity,UInt32 *out,void *data) {
    UInt32 required;OSStatus err=size(dr,o,p,a,qs,q,&required);if(err)return err;if(!out||capacity<required||(required&&!data))return kAudioHardwareBadPropertySizeError;*out=required;
    int kind=0;Device *d=lookup(o,&kind);uint32_t v=0;CFStringRef s=NULL;
    switch(a->mSelector) {
        case kAudioObjectPropertyBaseClass:v=kAudioObjectClassID;break;
        case kAudioObjectPropertyClass:v=o==1?kAudioPlugInClassID:kind?kAudioStreamClassID:kAudioDeviceClassID;break;
        case kAudioObjectPropertyOwner:v=o==1?kAudioObjectUnknown:kind?o-kind:kAudioObjectPlugInObject;break;
        case kAudioObjectPropertyName:s=d?d->name:CFSTR("AudioRoute");break;
        case kAudioObjectPropertyManufacturer:s=CFSTR("AudioRoute");break;
        case kAudioDevicePropertyDeviceUID:s=d->uid;break;
        case kAudioDevicePropertyModelUID:s=CFSTR("org.audioroute.virtual");break;
        case kAudioPlugInPropertyResourceBundle:s=CFSTR("");break;
        case kAudioPlugInPropertyDeviceList:case kAudioObjectPropertyOwnedObjects:case kAudioDevicePropertyStreams:objectList(o,a,data);return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            if(qs!=sizeof(CFStringRef)||!q)return kAudioHardwareBadPropertySizeError;
            for(uint32_t i=0;i<atomic_load(&deviceCount);++i)if(atomic_load(&devices[i].alive)&&CFEqual(*(CFStringRef*)q,devices[i].uid)){v=deviceID(i);break;}break;
        case kAudioDevicePropertyRelatedDevices:v=o;break;
        case kAudioDevicePropertyTransportType:v=kAudioDeviceTransportTypeVirtual;break;
        case kAudioDevicePropertyClockDomain:v=0;break;
        case kAudioDevicePropertyDeviceIsAlive:v=atomic_load(&d->alive);break;
        case kAudioDevicePropertyDeviceIsRunning:v=atomic_load(&d->running)>0;break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:v=channels(d,a,kind)>0;break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:v=a->mScope==kAudioObjectPropertyScopeOutput&&d->output>0;break;
        case kAudioDevicePropertyLatency:case kAudioDevicePropertySafetyOffset:v=0;break;
        case kAudioDevicePropertyIsHidden:v=0;break;
        case kAudioDevicePropertyZeroTimeStampPeriod:v=PERIOD;break;
        case kAudioDevicePropertyClockAlgorithm:v=kAudioDeviceClockAlgorithmRaw;break;
        case kAudioDevicePropertyNominalSampleRate:*(Float64*)data=d->rate;return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:*(AudioValueRange*)data=(AudioValueRange){d->rate,d->rate};return 0;
        case kAudioObjectPropertyControlList:return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:((UInt32*)data)[0]=1;((UInt32*)data)[1]=channels(d,a,kind)>1?2:1;return 0;
        case kAudioDevicePropertyPreferredChannelLayout: {
            memset(data,0,required);AudioChannelLayout *l=data;l->mChannelLayoutTag=kAudioChannelLayoutTag_UseChannelDescriptions;l->mNumberChannelDescriptions=channels(d,a,kind);
            for(UInt32 i=0;i<l->mNumberChannelDescriptions;++i)l->mChannelDescriptions[i].mChannelLabel=kAudioChannelLabel_Discrete_0+i;return 0;
        }
        case kAudioStreamPropertyIsActive:v=1;break;
        case kAudioStreamPropertyDirection:v=kind==1;break;
        case kAudioStreamPropertyTerminalType:v=kind==1?kAudioStreamTerminalTypeMicrophone:kAudioStreamTerminalTypeSpeaker;break;
        case kAudioStreamPropertyStartingChannel:v=1;break;
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:*(AudioStreamBasicDescription*)data=format(d,channels(d,a,kind));return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription *f=data;f->mFormat=format(d,channels(d,a,kind));f->mSampleRateRange=(AudioValueRange){d->rate,d->rate};return 0;
        }
        default:return kAudioHardwareUnknownPropertyError;
    }
    if(s)*(CFStringRef*)data=CFRetain(s);else *(UInt32*)data=v;return 0;
}
static OSStatus get(AudioServerPlugInDriverRef dr,AudioObjectID o,pid_t p,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 capacity,UInt32 *out,void *data) {
    // Keep dynamic list size and population in one control-plane snapshot.
    pthread_mutex_lock(&controlLock);
    OSStatus result=getUnlocked(dr,o,p,a,qs,q,capacity,out,data);
    pthread_mutex_unlock(&controlLock);return result;
}
static OSStatus set(AudioServerPlugInDriverRef dr,AudioObjectID o,pid_t p,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 n,const void *data){return has(dr,o,p,a)?kAudioHardwareUnsupportedOperationError:kAudioHardwareUnknownPropertyError;}
static OSStatus start(AudioServerPlugInDriverRef dr,AudioObjectID o,UInt32 clientID) {
    int k;Device *d=lookup(o,&k);if(!d||k||!atomic_load(&d->alive))return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&controlLock);uint32_t n=atomic_fetch_add(&d->running,1);
    if(!n){d->cacheValid=false;d->outputTimeValid=false;ar_transport_reset_input_reader(d->transport);atomic_store(&d->anchor,mach_absolute_time());atomic_fetch_add(&d->seed,1);}
    ar_transport_set_active_clients(d->transport,n+1);pthread_mutex_unlock(&controlLock);notify(o,kAudioDevicePropertyDeviceIsRunning);return 0;
}
static OSStatus stop(AudioServerPlugInDriverRef dr,AudioObjectID o,UInt32 c) {
    int k;Device *d=lookup(o,&k);if(!d||k)return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&controlLock);uint32_t n=atomic_load(&d->running);if(n)atomic_store(&d->running,--n);
    ar_transport_set_active_clients(d->transport,n);pthread_mutex_unlock(&controlLock);notify(o,kAudioDevicePropertyDeviceIsRunning);return 0;
}
static OSStatus timestamp(AudioServerPlugInDriverRef dr,AudioObjectID o,UInt32 c,Float64 *sample,UInt64 *time,UInt64 *seed) {
    int k;Device *d=lookup(o,&k);if(!d||k)return kAudioHardwareBadObjectError;
    uint64_t anchor=atomic_load(&d->anchor),now=mach_absolute_time();double ticks=ticksPerSecond/d->rate;
    uint64_t period=(uint64_t)((now-anchor)/(ticks*PERIOD));*sample=period*PERIOD;*time=anchor+(uint64_t)(period*PERIOD*ticks);*seed=atomic_load(&d->seed);return 0;
}
static OSStatus will(AudioServerPlugInDriverRef dr,AudioObjectID o,UInt32 c,UInt32 operation,Boolean *doIt,Boolean *inPlace) {
    int k;Device *d=lookup(o,&k);if(!d||k)return kAudioHardwareBadObjectError;
    *doIt=(operation==kAudioServerPlugInIOOperationReadInput&&d->input)||(operation==kAudioServerPlugInIOOperationWriteMix&&d->output);*inPlace=true;return 0;
}
static OSStatus phase(AudioServerPlugInDriverRef dr,AudioObjectID o,UInt32 c,UInt32 op,UInt32 n,const AudioServerPlugInIOCycleInfo *info){return 0;}
static void readCachedInput(Device *d,float *buffer,uint32_t frames,int64_t first) {
    int64_t end=first+frames;
    if(!d->cacheValid||first>d->cacheEnd+AR_TRANSPORT_CAPACITY) {
        d->cacheValid=true;d->cacheOrigin=first;d->cacheEnd=first;
    }
    if(end>d->cacheEnd) {
        int64_t cursor=d->cacheEnd;
        // A clock discontinuity starts a new input timeline rather than doing
        // unbounded work to fill the missing time span.
        if(end-cursor>AR_TRANSPORT_CAPACITY){cursor=first;d->cacheOrigin=first;}
        while(cursor<end) {
            uint32_t index=(uint64_t)cursor%AR_TRANSPORT_CAPACITY;
            uint32_t count=(uint32_t)(end-cursor),segment=AR_TRANSPORT_CAPACITY-index;
            if(count>segment)count=segment;
            ar_transport_read_input(d->transport,d->inputCache+index*d->input,count);
            cursor+=count;
        }
        d->cacheEnd=end;
    }
    int64_t oldest=d->cacheEnd-AR_TRANSPORT_CAPACITY;
    if(oldest<d->cacheOrigin)oldest=d->cacheOrigin;
    for(uint32_t i=0;i<frames;++i) {
        int64_t frame=first+i;
        if(frame<oldest||frame>=d->cacheEnd)memset(buffer+i*d->input,0,d->input*sizeof(float));
        else memcpy(buffer+i*d->input,d->inputCache+((uint64_t)frame%AR_TRANSPORT_CAPACITY)*d->input,d->input*sizeof(float));
    }
}
static OSStatus io(AudioServerPlugInDriverRef dr,AudioObjectID o,AudioObjectID stream,UInt32 c,UInt32 op,UInt32 n,const AudioServerPlugInIOCycleInfo *info,void *main,void *secondary) {
    int k;Device *d=lookup(o,&k);if(!d||k||!main||!info)return kAudioHardwareBadObjectError;
    if(n>AR_TRANSPORT_CAPACITY)return kAudioHardwareBadPropertySizeError;
    if(op==kAudioServerPlugInIOOperationReadInput){
        if(atomic_load(&d->alive))readCachedInput(d,main,n,(int64_t)info->mInputTime.mSampleTime);
        else memset(main,0,n*d->input*sizeof(float));
        if(n)ar_transport_input_read_callback(d->transport,info->mCurrentTime.mHostTime);
    } else if(op==kAudioServerPlugInIOOperationWriteMix&&atomic_load(&d->alive)) {
        int64_t first=(int64_t)info->mOutputTime.mSampleTime,end=first+n;
        // WriteMix represents the HAL's complete mix; don't enqueue it twice if
        // another client repeats an operation for already delivered sample time.
        uint32_t skip=d->outputTimeValid&&d->outputEnd>first?(uint32_t)fmin(n,d->outputEnd-first):0;
        if(skip<n)ar_transport_write_output(d->transport,(float*)main+skip*d->output,n-skip);
        if(!d->outputTimeValid||end>d->outputEnd)d->outputEnd=end;
        d->outputTimeValid=true;
    }
    ar_transport_driver_callback(d->transport,info->mCurrentTime.mHostTime,driverPID);return 0;
}
static AudioServerPlugInDriverInterface interface = {
    NULL,query,addRef,releaseRef,initialize,createDevice,destroyDevice,client,client,configuration,configuration,
    has,settable,size,get,set,start,stop,timestamp,will,phase,io,phase
};
__attribute__((visibility("default"))) void *AudioRouteFactory(CFAllocatorRef allocator,CFUUIDRef type) {
    return CFEqual(type,kAudioServerPlugInTypeUUID)?driver:NULL;
}
