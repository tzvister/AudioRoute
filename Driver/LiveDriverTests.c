/* Real Core Audio client verification. Uses an isolated named virtual endpoint;
 * never starts a physical device or changes a system default. */
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include "VirtualAudioTransport.h"
typedef struct { _Atomic uint64_t callbacks,good,bad; bool output; } Client;
static OSStatus callback(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    Client *c=context;atomic_fetch_add(&c->callbacks,1);
    if(input)for(UInt32 b=0;b<input->mNumberBuffers;++b){const AudioBuffer *a=&input->mBuffers[b];const float *f=a->mData;
        if(!f)continue;for(UInt32 i=0;i<a->mDataByteSize/sizeof(float);++i){float value=f[i];if(fabsf(value)>0.01f){if(fabsf(fabsf(value)-0.125f)<0.00001f)atomic_fetch_add(&c->good,1);else atomic_fetch_add(&c->bad,1);}}
    }
    if(output)for(UInt32 b=0;b<output->mNumberBuffers;++b){AudioBuffer *a=&output->mBuffers[b];float *f=a->mData;if(!f)continue;
        for(UInt32 i=0;i<a->mDataByteSize/sizeof(float);++i)f[i]=c->output?((i%a->mNumberChannels)?-0.25f:0.25f):0;
    }
    return 0;
}
typedef struct {ar_transport *transport;_Atomic bool stop;_Atomic uint64_t good,bad;} Writer;
static void *pump(void *context){Writer *w=context;float signal[480],returned[2048];for(uint32_t i=0;i<480;++i)signal[i]=i%2?-0.125f:0.125f;
    while(!atomic_load(&w->stop)){
        ar_transport_write_input_live(w->transport,signal,240);
        ar_transport_stats s;ar_transport_get_stats(w->transport,&s);uint64_t available=s.output_frames_written-s.output_frames_read;
        if(available){uint32_t n=available<1024?(uint32_t)available:1024;uint32_t copied=ar_transport_read_output(w->transport,returned,n);
            for(uint32_t i=0;i<copied*2;++i)if(fabsf(returned[i])>0.01f){if(fabsf(fabsf(returned[i])-0.25f)<0.00001f)atomic_fetch_add(&w->good,1);else atomic_fetch_add(&w->bad,1);}
        }
        usleep(5000);
    }return NULL;
}
int main(int argc,char **argv) {
    if(argc!=3){fprintf(stderr,"Usage: %s virtual-id output-channels\n",argv[0]);return 2;}
    bool duplex=atoi(argv[2])==2;char path[512];snprintf(path,sizeof(path),AR_SHARED_DIRECTORY "/devices/%s.shm",argv[1]);
    ar_transport *transport=ar_transport_open(path,2,duplex?2:0,0);if(!transport){perror("open transport");return 1;}
    CFStringRef uid=CFStringCreateWithFormat(NULL,NULL,CFSTR("org.audioroute.virtual.%s"),argv[1]);
    AudioObjectPropertyAddress address={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};AudioObjectID device=0;
    for(unsigned i=0;i<100&&!device;++i){UInt32 size=sizeof(device);AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,sizeof(uid),&uid,&size,&device);if(!device)usleep(100000);}CFRelease(uid);
    if(!device){fputs("FAIL: virtual endpoint not published within 10s.\n",stderr);ar_transport_close(transport);return 1;}
    Client a={0},b={0};a.output=duplex;AudioDeviceIOProcID first=NULL,second=NULL;OSStatus err;
    err=AudioDeviceCreateIOProcID(device,callback,&a,&first);if(err){fprintf(stderr,"FAIL CreateIOProc: %d\n",err);return 1;}
    err=AudioDeviceCreateIOProcID(device,callback,&b,&second);if(err){fprintf(stderr,"FAIL second CreateIOProc: %d\n",err);return 1;}
    Writer writer={.transport=transport};pthread_t thread;pthread_create(&thread,NULL,pump,&writer);
    err=AudioDeviceStart(device,first);if(!err)err=AudioDeviceStart(device,second);
    if(!err)usleep(2000000);else fprintf(stderr,"FAIL StartIO: %d\n",err);
    AudioDeviceStop(device,second);AudioDeviceStop(device,first);atomic_store(&writer.stop,true);pthread_join(thread,NULL);
    AudioDeviceDestroyIOProcID(device,second);AudioDeviceDestroyIOProcID(device,first);
    ar_transport_stats stats;ar_transport_get_stats(transport,&stats);ar_transport_close(transport);
    bool ok=!err&&atomic_load(&a.good)>1000&&atomic_load(&b.good)>1000&&!atomic_load(&a.bad)&&!atomic_load(&b.bad)&&(!duplex||(atomic_load(&writer.good)>1000&&!atomic_load(&writer.bad)));
    printf("{\"ok\":%s,\"device_id\":%u,\"first_client_samples\":%llu,\"second_client_samples\":%llu,\"output_samples\":%llu,\"driver_callbacks\":%llu,\"active_clients_after_stop\":%u}\n",ok?"true":"false",device,(unsigned long long)atomic_load(&a.good),(unsigned long long)atomic_load(&b.good),(unsigned long long)atomic_load(&writer.good),(unsigned long long)stats.driver_callbacks,stats.active_clients);
    return ok?0:1;
}
