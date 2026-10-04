/* Receives only the explicitly supplied AudioRoute virtual microphone. */
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
typedef struct {_Atomic uint64_t callbacks,good,bad;} Meter;
static OSStatus consume(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    Meter *meter=context;atomic_fetch_add(&meter->callbacks,1);
    if(input)for(UInt32 b=0;b<input->mNumberBuffers;++b){const AudioBuffer *buffer=&input->mBuffers[b];const float *samples=buffer->mData;if(!samples)continue;
        for(UInt32 i=0;i<buffer->mDataByteSize/sizeof(float);++i)if(fabsf(samples[i])>0.01f){
            if(fabsf(fabsf(samples[i])-0.1875f)<0.001f)atomic_fetch_add(&meter->good,1);else atomic_fetch_add(&meter->bad,1);
        }
    }
    return noErr;
}
int main(int argc,char **argv) {
    if(argc!=2)return 2;
    CFStringRef uid=CFStringCreateWithCString(NULL,argv[1],kCFStringEncodingUTF8);
    AudioObjectPropertyAddress address={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};AudioObjectID device=0;
    for(unsigned i=0;i<100&&!device;++i){UInt32 size=sizeof(device);AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,sizeof(uid),&uid,&size,&device);if(!device)usleep(100000);}CFRelease(uid);
    if(!device){fputs("FAIL: tap sink not published.\n",stderr);return 1;}
    Meter meter={0};AudioDeviceIOProcID io=NULL;OSStatus err=AudioDeviceCreateIOProcID(device,consume,&meter,&io);
    if(!err)err=AudioDeviceStart(device,io);
    if(!err)usleep(3000000);
    if(io){AudioDeviceStop(device,io);AudioDeviceDestroyIOProcID(device,io);}
    bool ok=!err&&atomic_load(&meter.good)>1000&&!atomic_load(&meter.bad);
    printf("{\"ok\":%s,\"test\":\"application_process_tap\",\"callbacks\":%llu,\"expected_samples\":%llu,\"unexpected_samples\":%llu,\"status\":%d}\n",ok?"true":"false",(unsigned long long)atomic_load(&meter.callbacks),(unsigned long long)atomic_load(&meter.good),(unsigned long long)atomic_load(&meter.bad),err);
    return ok?0:1;
}
