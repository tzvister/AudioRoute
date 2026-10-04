/* Stable-bundle application emits known PCM only to its supplied virtual output.
 * It never chooses a default device or opens a physical audio device. */
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <stdatomic.h>
static OSStatus produce(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    if(output)for(UInt32 b=0;b<output->mNumberBuffers;++b){AudioBuffer *buffer=&output->mBuffers[b];float *samples=buffer->mData;if(!samples)continue;
        for(UInt32 i=0;i<buffer->mDataByteSize/sizeof(float);++i)samples[i]=i%buffer->mNumberChannels?-0.1875f:0.1875f;
    }
    return noErr;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=3)return 2;
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [[NSString stringWithFormat:@"%d\n",getpid()] writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CFStringRef uid=CFStringCreateWithCString(NULL,argv[1],kCFStringEncodingUTF8);
        AudioObjectPropertyAddress address={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};AudioObjectID device=0;
        for(unsigned i=0;i<100&&!device;++i){UInt32 size=sizeof(device);AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,sizeof(uid),&uid,&size,&device);if(!device)usleep(100000);}CFRelease(uid);
        if(!device)return 3;
        AudioDeviceIOProcID io=NULL;OSStatus err=AudioDeviceCreateIOProcID(device,produce,NULL,&io);if(err)return 4;
        err=AudioDeviceStart(device,io);if(err){AudioDeviceDestroyIOProcID(device,io);return 5;}
        [NSApp run];AudioDeviceStop(device,io);AudioDeviceDestroyIOProcID(device,io);
    }return 0;
}
