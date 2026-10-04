/* Deterministic reproduction of real hardware delivery: MOTU sends 512-frame
 * packets at 44.1kHz; AirPods microphone sends480 frames at48kHz; virtual mixer
 * pulls256 frames while physical listening pulls512 frames. Independent clocks
 * have sustained drift and scheduling jitter. This is silent/offline. */
#include "AudioRT.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned allocations=0,deallocations=0;
static void *tracked_malloc(size_t n){allocations++;return malloc(n);}
static void *tracked_calloc(size_t n,size_t s){allocations++;return calloc(n,s);}
static void tracked_free(void *p){deallocations++;free(p);}
#define malloc tracked_malloc
#define calloc tracked_calloc
#define free tracked_free
#include "../../Sources/CAudioRT/AudioRT.c"
#undef malloc
#undef calloc
#undef free

static double source_jitter(unsigned index){return (index%100==0?0.003:0)+0.0003*sin(index*0.73);}
static void run(double guitar_rate,unsigned guitar_chunk,unsigned voice_chunk,unsigned send_chunk,unsigned listening_chunk,double drift,unsigned phase){
    ar_source *guitar=ar_source_create(1,NULL,guitar_rate),*voice=ar_source_create(1,NULL,48000);
    ar_sink *send=ar_sink_create(2,NULL,48000,0),*listen=ar_sink_create(2,NULL,48000,0);
    assert(guitar&&voice&&send&&listen);float stereo[]={1,1};
    assert(ar_sink_add_route(send,guitar,stereo));assert(ar_sink_add_route(send,voice,stereo));assert(ar_sink_add_route(listen,guitar,stereo));
    float g[4096],v[4096],a[8192],b[8192];for(unsigned i=0;i<4096;i++){g[i]=0.125f;v[i]=0.25f;}
    assert(guitar_chunk<=4096&&voice_chunk<=4096&&send_chunk<=4096&&listening_chunk<=4096);
    for(unsigned i=0;i<4;i++){ar_source_push(guitar,g,guitar_chunk);ar_source_push(voice,v,voice_chunk);}
    unsigned before_alloc=allocations,before_free=deallocations;double g_nominal=guitar_chunk/guitar_rate,v_nominal=voice_chunk/48000.0,a_nominal=send_chunk/48000.0,b_nominal=listening_chunk/48000.0;
    double next_g=g_nominal*(0.1+phase*0.07),next_v=v_nominal*0.8,next_a=a_nominal*0.7,next_b=b_nominal*0.3;
    double base_g=next_g,base_v=next_v,base_a=next_a,base_b=next_b;unsigned ng=1,nv=1,na=1,nb=1;uint64_t bad_a=0,bad_b=0;double t=0;
    // Drift stays negative long enough to expose a purely proportional
    // occupancy controller settling below safe headroom, then changes sign.
    while(t<180){
        t=fmin(fmin(next_g,next_v),fmin(next_a,next_b));
        if(t==next_g){ar_source_push(guitar,g,guitar_chunk);double actual=1+(t<120?-drift:drift);base_g+=g_nominal/actual;next_g=base_g+source_jitter(ng++);}
        else if(t==next_v){ar_source_push(voice,v,voice_chunk);base_v+=v_nominal/(1-0.00015);next_v=base_v+0.0007*sin(nv++*0.39);}
        else if(t==next_a){ar_sink_render(send,a,send_chunk);if(t>1)for(unsigned i=0;i<send_chunk*2;i++)if(fabsf(a[i]-0.375f)>0.00001f)bad_a++;base_a+=a_nominal;next_a=base_a+0.0005*sin(na++*0.59);}
        else {ar_sink_render(listen,b,listening_chunk);if(t>1)for(unsigned i=0;i<listening_chunk*2;i++)if(fabsf(b[i]-0.125f)>0.00001f)bad_b++;base_b+=b_nominal/(1+0.0001);next_b=base_b+0.0006*sin(nb++*0.47);}
        assert(allocations==before_alloc&&deallocations==before_free);
    }
    ar_stats sa=ar_sink_stats(send),sb=ar_sink_stats(listen),sg=ar_source_stats(guitar),sv=ar_source_stats(voice);
    printf("chunked: rate=%.0f producer=%u/%u consumer=%u/%u drift=%.0fppm phase=%u xruns=%llu/%llu overruns=%llu/%llu bad=%llu/%llu\n",guitar_rate,guitar_chunk,voice_chunk,send_chunk,listening_chunk,drift*1e6,phase,(unsigned long long)sa.underruns,(unsigned long long)sb.underruns,(unsigned long long)sg.overruns,(unsigned long long)sv.overruns,(unsigned long long)bad_a,(unsigned long long)bad_b);fflush(stdout);
    assert(sa.underruns==0&&sb.underruns==0&&sg.overruns==0&&sv.overruns==0&&bad_a==0&&bad_b==0);
    ar_sink_destroy(send);ar_sink_destroy(listen);ar_source_destroy(guitar);ar_source_destroy(voice);
}
static void delivery_buffers(void){
 ar_source *source=ar_source_create(1,NULL,48000);ar_sink *sink=ar_sink_create(2,NULL,48000,0);assert(source&&sink);float weights[]={1,1};assert(ar_sink_add_route(sink,source,weights));
 float input[512],left[512],right[512];for(unsigned i=0;i<512;i++)input[i]=0.125f;for(unsigned i=0;i<3;i++)ar_source_push(source,input,512);
 size_t size=offsetof(AudioBufferList,mBuffers)+2*sizeof(AudioBuffer);AudioBufferList *out=calloc(1,size);assert(out);out->mNumberBuffers=2;
 out->mBuffers[0]=(AudioBuffer){1,sizeof(left),left};out->mBuffers[1]=(AudioBuffer){1,sizeof(right),right};
 ar_sink_set_active(sink,true);unsigned before=allocations,before_free=deallocations;
 playback_proc(0,NULL,NULL,NULL,out,NULL,sink);ar_stats first=ar_sink_stats(sink);
 assert(first.device_frames_written==512&&first.device_nonzero_samples_written==1024&&first.unavailable_output_buffers==0&&first.device_write_host_time>0);
 for(unsigned i=0;i<512;i++){assert(left[i]==0.125f);assert(right[i]==0.125f);}
 // HAL may expose disabled streams as NULL with a nonzero mDataByteSize.
 // The mix meter must not claim complete delivery to an unavailable stream.
 out->mBuffers[1].mData=NULL;ar_source_push(source,input,512);playback_proc(0,NULL,NULL,NULL,out,NULL,sink);ar_stats unavailable=ar_sink_stats(sink);
 assert(unavailable.device_frames_written==512&&unavailable.device_nonzero_samples_written==1536&&unavailable.unavailable_output_buffers==1&&unavailable.peak==0);
 assert(allocations==before&&deallocations==before_free);
 ar_sink_destroy(sink);ar_source_destroy(source);free(out);puts("Real output ABL delivery/disabled-stream counters passed");
}
int main(void){
    delivery_buffers();
    for(unsigned phase=0;phase<4;phase++)run(44100,512,480,256,512,0.001,phase);
    run(48000,512,480,256,512,0.0005,1);
    run(96000,1024,480,256,512,0.001,2);
    run(44100,512,480,512,256,0.001,3);
    puts("Chunked hardware clock/jitter regression passed; zero callback allocations");
}
