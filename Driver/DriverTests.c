/* Exercises the real plug-in vtable against an in-process mock HAL host.
 * Uses temporary files only; never loads or installs into coreaudiod. */
#include "AudioRouteDriver.c"
#include <assert.h>
#include <stdlib.h>
#include <errno.h>
static _Atomic uint32_t notifications;
static OSStatus changed(AudioServerPlugInHostRef h,AudioObjectID o,UInt32 n,const AudioObjectPropertyAddress *p){atomic_fetch_add(&notifications,1);return 0;}
static void writeRegistry(const char *xml) {
    FILE *f=fopen(AR_SHARED_DIRECTORY "/registry.plist","w");assert(f);assert(fwrite(xml,1,strlen(xml),f)==strlen(xml));assert(!fclose(f));
}
#define XML_PREFIX "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>devices</key><array>"
#define MIC "<dict><key>id</key><string>test-mic</string><key>name</key><string>Test Microphone</string><key>inputChannels</key><integer>2</integer><key>outputChannels</key><integer>0</integer><key>sampleRate</key><integer>48000</integer></dict>"
#define DUPLEX "<dict><key>id</key><string>test-duplex</string><key>name</key><string>Test Duplex</string><key>inputChannels</key><integer>1</integer><key>outputChannels</key><integer>2</integer></dict>"
#define XML_SUFFIX "</array></dict></plist>"
static void *churnRegistry(void *unused) {
    for(unsigned i=0;i<200;++i){writeRegistry(i%2?XML_PREFIX MIC DUPLEX XML_SUFFIX:XML_PREFIX DUPLEX XML_SUFFIX);refreshRegistry();}
    return NULL;
}
static UInt32 getInt(AudioObjectID o,AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress a={selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 value=0,n=0;
    assert(!(*driver)->GetPropertyData(driver,o,0,&a,0,NULL,sizeof(value),&n,&value));assert(n==sizeof(value));return value;
}
int main(void) {
    assert(!mkdir(AR_SHARED_DIRECTORY,0700)||errno==EEXIST);
    assert(!mkdir(AR_SHARED_DIRECTORY "/devices",0700)||errno==EEXIST);
    ar_transport *mic=ar_transport_open(AR_SHARED_DIRECTORY "/devices/test-mic.shm",2,0,1);
    ar_transport *duplex=ar_transport_open(AR_SHARED_DIRECTORY "/devices/test-duplex.shm",1,2,1);assert(mic&&duplex);
    // Exercise the actual Mach shared-memory boxing/mapping used across the HAL sandbox.
    xpc_object_t boxed=ar_transport_export_shared_memory(mic);assert(boxed);
    ar_transport *mapped=ar_transport_import_shared_memory(boxed,2,0);assert(mapped);xpc_release(boxed);
    float boxedSignal[]={0.25f,-0.25f},boxedCopy[2];assert(ar_transport_write_input(mic,boxedSignal,1)==1);
    assert(ar_transport_read_input(mapped,boxedCopy,1)==1);assert(!memcmp(boxedSignal,boxedCopy,sizeof(boxedSignal)));ar_transport_close(mapped);
    assert(!ar_transport_open(AR_SHARED_DIRECTORY "/devices/test-mic.shm",1,0,0));
    // A registry owner can alter shared metadata: RT copy bounds must continue
    // using the channel counts validated and cached when this handle opened.
    int sharedFD=open(AR_SHARED_DIRECTORY "/devices/test-mic.shm",O_RDWR);assert(sharedFD>=0);struct stat sharedStat;assert(!fstat(sharedFD,&sharedStat));
    uint32_t *sharedHeader=mmap(NULL,sharedStat.st_size,PROT_READ|PROT_WRITE,MAP_SHARED,sharedFD,0);assert(sharedHeader!=MAP_FAILED);close(sharedFD);
    sharedHeader[2]=UINT32_MAX;sharedHeader[3]=UINT32_MAX;
    float boundSignal[2]={0.1f,-0.1f},boundReceived[2];assert(ar_transport_write_input(mic,boundSignal,1)==1);assert(ar_transport_read_input(mic,boundReceived,1)==1);assert(!memcmp(boundSignal,boundReceived,sizeof(boundSignal)));
    ar_transport_stats safeStats;ar_transport_get_stats(mic,&safeStats);assert(safeStats.input_channels==2&&safeStats.output_channels==0);
    sharedHeader[2]=2;sharedHeader[3]=0;munmap(sharedHeader,sharedStat.st_size);

    // Ring saturation drops new frames and zero-fills shortages.
    float *large=calloc((AR_TRANSPORT_CAPACITY+3)*2,sizeof(float));assert(large);
    for(uint32_t i=0;i<(AR_TRANSPORT_CAPACITY+3)*2;++i)large[i]=(float)i;
    assert(ar_transport_write_input(mic,large,AR_TRANSPORT_CAPACITY+3)==AR_TRANSPORT_CAPACITY);
    float *copy=calloc((AR_TRANSPORT_CAPACITY+3)*2,sizeof(float));assert(copy);
    assert(ar_transport_read_input(mic,copy,AR_TRANSPORT_CAPACITY+3)==AR_TRANSPORT_CAPACITY);
    assert(!memcmp(large,copy,AR_TRANSPORT_CAPACITY*2*sizeof(float)));
    for(uint32_t i=AR_TRANSPORT_CAPACITY*2;i<(AR_TRANSPORT_CAPACITY+3)*2;++i)assert(copy[i]==0);
    free(large);free(copy);
    writeRegistry(XML_PREFIX MIC DUPLEX XML_SUFFIX);
    AudioServerPlugInHostInterface h={0};h.PropertiesChanged=changed;
    assert(AudioRouteFactory(NULL,kAudioServerPlugInTypeUUID)==driver);
    assert(!(*driver)->Initialize(driver,&h));assert(atomic_load(&deviceCount)==2);
    AudioObjectPropertyAddress a={kAudioPlugInPropertyDeviceList,kAudioObjectPropertyScopeGlobal,0};UInt32 n=0;AudioObjectID list[2];
    assert(!(*driver)->GetPropertyData(driver,1,0,&a,0,NULL,sizeof(list),&n,list));assert(n==sizeof(list)&&list[0]==100&&list[1]==103);
    assert(getInt(100,kAudioObjectPropertyClass)==kAudioDeviceClassID);
    assert(getInt(101,kAudioStreamPropertyDirection)==1);assert(getInt(105,kAudioStreamPropertyDirection)==0);
    a.mSelector=kAudioDevicePropertyDeviceUID;CFStringRef uid=NULL;
    assert(!(*driver)->GetPropertyData(driver,100,0,&a,0,NULL,sizeof(uid),&n,&uid));assert(CFEqual(uid,CFSTR("org.audioroute.virtual.test-mic")));CFRelease(uid);
    a.mSelector=kAudioStreamPropertyPhysicalFormat;AudioStreamBasicDescription f;
    assert(!(*driver)->GetPropertyData(driver,101,0,&a,0,NULL,sizeof(f),&n,&f));assert(f.mSampleRate==48000&&f.mChannelsPerFrame==2&&f.mBytesPerFrame==8);
    assert(!(*driver)->StartIO(driver,100,42));assert(!(*driver)->StartIO(driver,100,43));
    assert(getInt(100,kAudioDevicePropertyDeviceIsRunning)==1);
    ar_transport_stats stats;ar_transport_get_stats(mic,&stats);assert(stats.active_clients==2);
    float signal[]={0.1f,-0.2f,0.3f,-0.4f},received[4]={0};
    assert(ar_transport_write_input_live(mic,signal,2)==2);
    AudioServerPlugInIOCycleInfo info={0};info.mCurrentTime.mHostTime=mach_absolute_time();
    assert(!(*driver)->DoIOOperation(driver,100,101,42,kAudioServerPlugInIOOperationReadInput,2,&info,received,NULL));assert(!memcmp(signal,received,sizeof(signal)));
    // Two HAL clients reading the same sample-time range share cached PCM.
    memset(received,0,sizeof(received));
    assert(!(*driver)->DoIOOperation(driver,100,101,43,kAudioServerPlugInIOOperationReadInput,2,&info,received,NULL));assert(!memcmp(signal,received,sizeof(signal)));
    ar_transport_get_stats(mic,&stats);assert(stats.input_frames_written==stats.input_frames_read);
    assert(!(*driver)->DoIOOperation(driver,103,105,44,kAudioServerPlugInIOOperationWriteMix,2,&info,signal,NULL));
    assert(ar_transport_read_output(duplex,received,2)==2);assert(!memcmp(signal,received,sizeof(signal)));
    Float64 sample;UInt64 time,seed;assert(!(*driver)->GetZeroTimeStamp(driver,100,42,&sample,&time,&seed));assert(time<=mach_absolute_time()&&seed>1);
    assert(!(*driver)->StopIO(driver,100,42));assert(!(*driver)->StopIO(driver,100,43));ar_transport_get_stats(mic,&stats);assert(!stats.active_clients&&stats.driver_callbacks==2);
    uint64_t before=stats.input_frames_written;assert(ar_transport_write_input_live(mic,signal,2)==2);ar_transport_get_stats(mic,&stats);assert(stats.input_frames_written==before);
    writeRegistry(XML_PREFIX DUPLEX XML_SUFFIX);refreshRegistry();assert(!getInt(100,kAudioDevicePropertyDeviceIsAlive));
    a=(AudioObjectPropertyAddress){kAudioPlugInPropertyDeviceList,kAudioObjectPropertyScopeGlobal,0};assert(!(*driver)->GetPropertyData(driver,1,0,&a,0,NULL,sizeof(list),&n,list));assert(n==4&&list[0]==103);
    writeRegistry(XML_PREFIX MIC DUPLEX XML_SUFFIX);refreshRegistry();assert(getInt(100,kAudioDevicePropertyDeviceIsAlive));assert(atomic_load(&notifications)>0);
    // Dynamic device publication cannot race list sizing into a caller overflow.
    pthread_t churn;assert(!pthread_create(&churn,NULL,churnRegistry,NULL));
    for(unsigned i=0;i<5000;++i){struct {AudioObjectID id;uint32_t guard;} tiny={0,0xa55aa55a};UInt32 used=0;
        OSStatus status=(*driver)->GetPropertyData(driver,1,0,&a,0,NULL,sizeof(tiny.id),&used,&tiny.id);
        assert(status==0||status==kAudioHardwareBadPropertySizeError);assert(tiny.guard==0xa55aa55a);if(!status)assert(used<=sizeof(tiny.id));
    }assert(!pthread_join(churn,NULL));
    dispatch_source_cancel(registryTimer);ar_transport_close(mic);ar_transport_close(duplex);
    puts("HAL vtable, dynamic registry races, immutable bounds, formats, clocks, multi-client PCM, XPC sharing, idle discard, saturation and client statistics passed.");return 0;
}
