/* Native HAL clients for the full audiorouted integration test. Audio is
 * produced/read only through explicitly named temporary virtual endpoints.
 * Neither this client nor the scenario opens a physical microphone/speaker. */
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

typedef struct { bool producer; _Atomic bool measure; _Atomic float expected;
    _Atomic uint64_t callbacks, good, bad, silence; } Client;
typedef struct {uint64_t good_a,bad_a,silence_a,good_b,bad_b,silence_b;} Result;
static OSStatus callback(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *it,AudioBufferList *output,const AudioTimeStamp *ot,void *context) {
    Client *client=context;atomic_fetch_add_explicit(&client->callbacks,1,memory_order_relaxed);
    if(client->producer&&output){unsigned channel_offset=0;
        for(UInt32 b=0;b<output->mNumberBuffers;b++){AudioBuffer *buffer=&output->mBuffers[b];float *data=buffer->mData;if(!data||!buffer->mNumberChannels)continue;
            for(UInt32 i=0;i<buffer->mDataByteSize/sizeof(float);i++)data[i]=(channel_offset+i%buffer->mNumberChannels)%2?-0.125f:0.125f;
            channel_offset+=buffer->mNumberChannels;
        }
    } else if(input&&atomic_load_explicit(&client->measure,memory_order_relaxed)){
        const float amplitude=atomic_load_explicit(&client->expected,memory_order_relaxed);unsigned channel_offset=0;
        uint64_t good=0,bad=0,silence=0;
        for(UInt32 b=0;b<input->mNumberBuffers;b++){const AudioBuffer *buffer=&input->mBuffers[b];const float *data=buffer->mData;if(!data||!buffer->mNumberChannels)continue;
            for(UInt32 i=0;i<buffer->mDataByteSize/sizeof(float);i++){float expected=(channel_offset+i%buffer->mNumberChannels)%2?-amplitude:amplitude;
                if(fabsf(data[i])<0.000001f)silence++;else if(isfinite(data[i])&&fabsf(data[i]-expected)<0.00001f)good++;else bad++;
            }channel_offset+=buffer->mNumberChannels;
        }
        atomic_fetch_add_explicit(&client->good,good,memory_order_relaxed);atomic_fetch_add_explicit(&client->bad,bad,memory_order_relaxed);atomic_fetch_add_explicit(&client->silence,silence,memory_order_relaxed);
    }return noErr;
}
static AudioDeviceID resolve(const char *id) {
    CFStringRef uid=CFStringCreateWithFormat(NULL,NULL,CFSTR("org.audioroute.virtual.%s"),id);
    AudioObjectPropertyAddress address={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};AudioDeviceID device=0;
    for(unsigned i=0;i<150&&!device;i++){UInt32 size=sizeof(device);AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,sizeof(uid),&uid,&size,&device);if(!device)usleep(100000);}CFRelease(uid);return device;
}
static bool write_marker(const char *path,unsigned stage) {FILE *file=fopen(path,"w");if(!file)return false;fprintf(file,"%u\n",stage);return fclose(file)==0;}
static bool wait_command(const char *path,unsigned stage) {
    for(unsigned i=0;i<150;i++){FILE *file=fopen(path,"r");unsigned value=0;if(file){int read=fscanf(file,"%u",&value);fclose(file);if(read==1&&value==stage)return true;}usleep(100000);}return false;
}
static void reset(Client *client,float expected){atomic_store(&client->measure,false);atomic_store(&client->good,0);atomic_store(&client->bad,0);atomic_store(&client->silence,0);atomic_store(&client->expected,expected);atomic_store(&client->measure,true);}
static Result measure(Client *a,Client *b,float expected_a,float expected_b){reset(a,expected_a);reset(b,expected_b);usleep(2000000);atomic_store(&a->measure,false);atomic_store(&b->measure,false);return(Result){atomic_load(&a->good),atomic_load(&a->bad),atomic_load(&a->silence),atomic_load(&b->good),atomic_load(&b->bad),atomic_load(&b->silence)};}
static bool good(Result result){return result.good_a>48000&&result.good_b>48000&&!result.bad_a&&!result.bad_b;}
int main(int argc,char **argv){
    if(argc!=7){fprintf(stderr,"Usage: %s source-id sink-a-id sink-b-id ready-file command-file report-file\n",argv[0]);return 2;}
    const char *ids[]={argv[1],argv[2],argv[3]};AudioDeviceID devices[3]={0};AudioDeviceIOProcID procedures[3]={0};Client clients[3]={0};clients[0].producer=true;
    OSStatus error=noErr;unsigned created=0,started=0;Result results[3]={0};bool ok=false;
    for(unsigned i=0;i<3;i++){devices[i]=resolve(ids[i]);if(!devices[i]){fprintf(stderr,"Virtual endpoint %s was not published.\n",ids[i]);goto cleanup;}
        error=AudioDeviceCreateIOProcID(devices[i],callback,&clients[i],&procedures[i]);if(error){fprintf(stderr,"CreateIOProc %s: %d\n",ids[i],error);goto cleanup;}created++;
    }
    // Consumers start first to prevent stale producer backlog.
    for(unsigned j=0;j<3;j++){unsigned i=(j+1)%3;error=AudioDeviceStart(devices[i],procedures[i]);if(error){fprintf(stderr,"StartIO %s: %d\n",ids[i],error);goto cleanup;}started|=1u<<i;}
    usleep(1500000);results[0]=measure(&clients[1],&clients[2],0.125f,0.25f);
    if(!good(results[0])){fprintf(stderr,"Initial daemon routing did not produce expected independent mixes.\n");goto cleanup;}
    if(!write_marker(argv[4],0)||!wait_command(argv[5],1)){fputs("First CLI level change did not arrive.\n",stderr);goto cleanup;}
    usleep(1000000);results[1]=measure(&clients[1],&clients[2],0.0625f,0.25f);
    if(!good(results[1])){fputs("Per-output input gain change did not remain isolated.\n",stderr);goto cleanup;}
    if(!write_marker(argv[4],1)||!wait_command(argv[5],2)){fputs("Second CLI level change did not arrive.\n",stderr);goto cleanup;}
    usleep(1000000);results[2]=measure(&clients[1],&clients[2],0.0625f,0.125f);
    if(!good(results[2])){fputs("Output master gain change did not remain isolated.\n",stderr);goto cleanup;}
    ok=true;write_marker(argv[4],2);
cleanup:
    for(unsigned i=0;i<3;i++)if(started&(1u<<i))AudioDeviceStop(devices[i],procedures[i]);
    for(unsigned i=0;i<created;i++)AudioDeviceDestroyIOProcID(devices[i],procedures[i]);
    FILE *report=fopen(argv[6],"w");if(!report)report=stdout;
    fprintf(report,"{\"ok\":%s,\"source_callbacks\":%llu,\"stages\":[",ok?"true":"false",(unsigned long long)atomic_load(&clients[0].callbacks));
    for(unsigned stage=0;stage<3;stage++)fprintf(report,"%s{\"stage\":%u,\"sink_a_samples\":%llu,\"sink_a_incorrect\":%llu,\"sink_a_silent\":%llu,\"sink_b_samples\":%llu,\"sink_b_incorrect\":%llu,\"sink_b_silent\":%llu}",stage?",":"",stage,(unsigned long long)results[stage].good_a,(unsigned long long)results[stage].bad_a,(unsigned long long)results[stage].silence_a,(unsigned long long)results[stage].good_b,(unsigned long long)results[stage].bad_b,(unsigned long long)results[stage].silence_b);
    fputs("]}\n",report);if(report!=stdout)fclose(report);return ok?0:1;
}
