#include "AudioRT.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <mach/mach_time.h>

// Each edge has its own SPSC buffer, so reading one destination never consumes
// another destination's mix. Allocation and topology changes occur off callbacks.
typedef struct {
 float *samples;
 uint32_t channels;
 atomic_uint_fast64_t read, write;
 double phase, filtered_available, drift_integral;
 atomic_uint producer_block;
 bool primed;
} ar_ring;
typedef struct {
 atomic_uint_fast64_t callbacks, frames, last, underruns, overruns, clips, invalid;
 atomic_uint_fast64_t device_frames_written, device_nonzero_samples_written, unavailable_output_buffers, device_write_host_time;
 _Atomic float peak, rms;
} counters;
typedef struct { ar_source *source; ar_ring *ring; float *matrix; } route;
struct ar_source {
 uint32_t channels, indices[AR_MAX_CHANNELS], count;
 double rate;
 ar_ring *rings[AR_MAX_ROUTES];
 counters stats;
 AudioDeviceID device;
 AudioDeviceIOProcID io;
 pthread_t thread;
 bool threaded;
 atomic_bool running, active;
 ar_read_fn reader;
 void *context;
 float *scratch;
};
struct ar_sink {
 uint32_t channels, indices[AR_MAX_CHANNELS], count;
 double rate;
 float ceiling;
 route routes[AR_MAX_ROUTES];
 counters stats;
 AudioDeviceID device;
 AudioDeviceIOProcID io;
 pthread_t thread;
 bool threaded;
 atomic_bool running, active;
 ar_write_fn writer;
 void *context;
 float *scratch;
};
static void prewarm(float *samples,size_t count){volatile float *p=samples;for(size_t i=0;i<count;i+=1024)p[i]=0;if(count)p[count-1]=0;}
static ar_ring *new_ring(uint32_t channels) {
 ar_ring *r=calloc(1,sizeof(*r));
 if(!r) return NULL;
 r->channels=channels; r->samples=calloc(AR_RING_FRAMES*channels,sizeof(float));
 if(!r->samples){ free(r); return NULL; } prewarm(r->samples,AR_RING_FRAMES*channels);return r;
}
static void meter(counters *c,const float *samples,uint32_t count,uint32_t frames) {
 float peak=0; double energy=0; uint64_t clips=0, invalid=0;
 for(uint32_t i=0;i<count;i++){ float sample=samples[i];if(!isfinite(sample)){invalid++;sample=0;}float a=fabsf(sample); if(a>peak)peak=a; energy+=(double)sample*sample; if(a>1)clips++; }
 atomic_store_explicit(&c->peak,peak,memory_order_relaxed);
 atomic_store_explicit(&c->rms,count?sqrt(energy/count):0,memory_order_relaxed);
 atomic_fetch_add_explicit(&c->clips,clips,memory_order_relaxed);
 atomic_fetch_add_explicit(&c->invalid,invalid,memory_order_relaxed);
 atomic_fetch_add_explicit(&c->frames,frames,memory_order_relaxed);
 atomic_fetch_add_explicit(&c->callbacks,1,memory_order_relaxed);
 atomic_store_explicit(&c->last,mach_absolute_time(),memory_order_relaxed);
}
ar_source *ar_source_create(uint32_t n,const uint32_t *indices,double rate) {
 if(!n||n>AR_MAX_CHANNELS||rate<=0) return NULL;
 ar_source *s=calloc(1,sizeof(*s)); if(!s)return NULL;
 s->channels=n;s->rate=rate;
 for(uint32_t i=0;i<n;i++)s->indices[i]=indices?indices[i]:i;
 s->scratch=calloc(AR_BLOCK_FRAMES*n,sizeof(float));
 if(!s->scratch){free(s);return NULL;} prewarm(s->scratch,AR_BLOCK_FRAMES*n);return s;
}
ar_sink *ar_sink_create(uint32_t n,const uint32_t *indices,double rate,float ceiling) {
 if(!n||n>AR_MAX_CHANNELS||rate<=0)return NULL;
 ar_sink *s=calloc(1,sizeof(*s));if(!s)return NULL;
 s->channels=n;s->rate=rate;s->ceiling=ceiling;
 for(uint32_t i=0;i<n;i++)s->indices[i]=indices?indices[i]:i;
 s->scratch=calloc(AR_BLOCK_FRAMES*n,sizeof(float));
 if(!s->scratch){free(s);return NULL;}prewarm(s->scratch,AR_BLOCK_FRAMES*n);return s;
}
bool ar_sink_add_route(ar_sink *sink,ar_source *source,const float *matrix){
 if(!sink||!source||!matrix||sink->count>=AR_MAX_ROUTES||source->count>=AR_MAX_ROUTES)return false;
 for(uint32_t i=0;i<sink->channels*source->channels;i++)if(!isfinite(matrix[i]))return false;
 ar_ring *ring=new_ring(source->channels);if(!ring)return false;
 float *m=malloc(source->channels*sink->channels*sizeof(float));
 if(!m){free(ring->samples);free(ring);return false;}
 memcpy(m,matrix,source->channels*sink->channels*sizeof(float));
 sink->routes[sink->count++]=(route){source,ring,m};source->rings[source->count++]=ring;return true;
}
void ar_source_push(ar_source *s,const float *data,uint32_t frames){
 if(!s||!data)return;
 meter(&s->stats,data,frames*s->channels,frames);
 for(uint32_t i=0;i<s->count;i++){
  ar_ring *r=s->rings[i];uint32_t batch=frames>AR_BLOCK_FRAMES?AR_BLOCK_FRAMES:frames;
  if(batch>atomic_load_explicit(&r->producer_block,memory_order_relaxed))atomic_store_explicit(&r->producer_block,batch,memory_order_relaxed);
  uint64_t w=atomic_load_explicit(&r->write,memory_order_relaxed), rd=atomic_load_explicit(&r->read,memory_order_acquire);
  uint32_t n=frames;uint64_t space=AR_RING_FRAMES-(w-rd);if(n>space){n=(uint32_t)space;atomic_fetch_add_explicit(&s->stats.overruns,1,memory_order_relaxed);}
  for(uint32_t f=0;f<n;f++)for(uint32_t c=0;c<s->channels;c++){float value=data[f*s->channels+c];r->samples[((w+f)%AR_RING_FRAMES)*s->channels+c]=isfinite(value)?value:0;}
  atomic_store_explicit(&r->write,w+n,memory_order_release);
 }
}
void ar_sink_render(ar_sink *s,float *out,uint32_t frames){
 memset(out,0,frames*s->channels*sizeof(float));
 for(uint32_t q=0;q<s->count;q++){
  route *edge=&s->routes[q];ar_ring *r=edge->ring;
  uint64_t rd=atomic_load_explicit(&r->read,memory_order_relaxed),w=atomic_load_explicit(&r->write,memory_order_acquire);
  uint64_t available=w-rd;
  // Hardware delivers whole producer packets, not one packet per render.
  // Reserve at least the larger producer/consumer block and include half a
  // producer packet in the mean-occupancy target to account for its sawtooth.
  // This prevents a256-frame virtual sink from draining a512-frame USB source
  // down to an unsafe two-consumer-block target between hardware callbacks.
  double base=edge->source->rate/s->rate;
  double needed=ceil(frames*base)+2;
  double producer=atomic_load_explicit(&r->producer_block,memory_order_relaxed);
  if(producer<1)producer=needed;
  double reserve=fmax(producer,needed);
  double target=fmin(AR_RING_FRAMES*0.75,needed+reserve+producer*0.5);
  double prime=fmin(AR_RING_FRAMES*0.75,needed+reserve);
  if(!r->primed){if(available<prime){continue;}r->primed=true;r->phase=0;r->filtered_available=available;}
  // Smooth packet/scheduler jitter before controlling the clock ratio. A PI
  // controller keeps finite headroom during sustained negative clock drift;
  // a proportional-only controller would settle below target by drift/gain.
  double dt=frames/s->rate;
  double alpha=fmin(1,dt/0.25);
  r->filtered_available+=alpha*((double)available-r->filtered_available);
  double error=(r->filtered_available-target)/reserve;
  double proportional=0.003*error;
  double integral=r->drift_integral+0.0002*error*dt;
  double requested=proportional+integral;
  // Anti-windup: do not integrate further into the bounded correction limit.
  if((requested<0.002||error<0)&&(requested>-0.002||error>0))r->drift_integral=fmax(-0.002,fmin(0.002,integral));
  double correction=fmax(-0.002,fmin(0.002,proportional+r->drift_integral));
  double step=base*(1+correction);
  uint32_t processed=0;
  for(uint32_t f=0;f<frames;f++){
   uint64_t at=(uint64_t)r->phase;double fraction=r->phase-at;
   if(at+1>=available){atomic_fetch_add_explicit(&s->stats.underruns,1,memory_order_relaxed);r->primed=false;break;}
   const float *a=r->samples+((rd+at)%AR_RING_FRAMES)*r->channels,*b=r->samples+((rd+at+1)%AR_RING_FRAMES)*r->channels;
   for(uint32_t d=0;d<s->channels;d++)for(uint32_t c=0;c<r->channels;c++)out[f*s->channels+d]+=(a[c]+(b[c]-a[c])*fraction)*edge->matrix[d*r->channels+c];
   r->phase+=step;processed++;
  }
  uint64_t consumed=(uint64_t)r->phase;
  if(consumed>available)consumed=available;
  r->phase-=consumed;atomic_store_explicit(&r->read,rd+consumed,memory_order_release);
  (void)processed;
 }
 for(uint32_t i=0;i<frames*s->channels;i++)if(!isfinite(out[i])){out[i]=0;atomic_fetch_add_explicit(&s->stats.invalid,1,memory_order_relaxed);}
 meter(&s->stats,out,frames*s->channels,frames);
 if(s->ceiling>0)for(uint32_t i=0;i<frames*s->channels;i++)out[i]=fmaxf(-s->ceiling,fminf(s->ceiling,out[i]));
}
static uint32_t abl_frames(const AudioBufferList *list){
 if(!list||!list->mNumberBuffers)return 0;
 const AudioBuffer *b=&list->mBuffers[0];return b->mNumberChannels?b->mDataByteSize/(sizeof(float)*b->mNumberChannels):0;
}
static float abl_get(const AudioBufferList *list,uint32_t frame,uint32_t channel){
 for(uint32_t b=0;b<list->mNumberBuffers;b++){const AudioBuffer *buf=&list->mBuffers[b];if(channel<buf->mNumberChannels){return buf->mData&&((uint64_t)frame*buf->mNumberChannels+channel)*sizeof(float)<buf->mDataByteSize?((float*)buf->mData)[frame*buf->mNumberChannels+channel]:0;}channel-=buf->mNumberChannels;}return 0;
}
static bool abl_set(AudioBufferList *list,uint32_t frame,uint32_t channel,float value){
 for(uint32_t b=0;b<list->mNumberBuffers;b++){AudioBuffer *buf=&list->mBuffers[b];if(channel<buf->mNumberChannels){if(buf->mData&&((uint64_t)frame*buf->mNumberChannels+channel)*sizeof(float)<buf->mDataByteSize){((float*)buf->mData)[frame*buf->mNumberChannels+channel]=value;return true;}return false;}channel-=buf->mNumberChannels;}return false;
}
static OSStatus capture_proc(AudioDeviceID device,const AudioTimeStamp *now,const AudioBufferList *in,const AudioTimeStamp *inputTime,AudioBufferList *out,const AudioTimeStamp *outputTime,void *context){
 ar_source *s=context; if(!atomic_load_explicit(&s->active,memory_order_relaxed))return noErr; uint32_t frames=abl_frames(in);
 for(uint32_t start=0;start<frames;start+=AR_BLOCK_FRAMES){uint32_t n=frames-start;if(n>AR_BLOCK_FRAMES)n=AR_BLOCK_FRAMES;
  for(uint32_t f=0;f<n;f++)for(uint32_t c=0;c<s->channels;c++)s->scratch[f*s->channels+c]=abl_get(in,start+f,s->indices[c]);
  ar_source_push(s,s->scratch,n);
 }return noErr;
}
static OSStatus playback_proc(AudioDeviceID device,const AudioTimeStamp *now,const AudioBufferList *in,const AudioTimeStamp *inputTime,AudioBufferList *out,const AudioTimeStamp *outputTime,void *context){
 ar_sink *s=context;if(!out){atomic_fetch_add_explicit(&s->stats.unavailable_output_buffers,1,memory_order_relaxed);atomic_store_explicit(&s->stats.peak,0,memory_order_relaxed);atomic_store_explicit(&s->stats.rms,0,memory_order_relaxed);return noErr;}uint32_t frames=abl_frames(out);
 uint64_t delivered=0,nonzero=0;bool unavailable=false;
 for(uint32_t b=0;b<out->mNumberBuffers;b++)if(out->mBuffers[b].mData)memset(out->mBuffers[b].mData,0,out->mBuffers[b].mDataByteSize);
 if(!atomic_load_explicit(&s->active,memory_order_relaxed))return noErr;
 for(uint32_t start=0;start<frames;start+=AR_BLOCK_FRAMES){uint32_t n=frames-start;if(n>AR_BLOCK_FRAMES)n=AR_BLOCK_FRAMES;
  ar_sink_render(s,s->scratch,n);
  for(uint32_t f=0;f<n;f++){bool complete=true;for(uint32_t c=0;c<s->channels;c++){float value=s->scratch[f*s->channels+c];bool wrote=abl_set(out,start+f,s->indices[c],value);complete=complete&&wrote;if(wrote&&value!=0)nonzero++;}if(complete)delivered++;else unavailable=true;}
 }
 atomic_fetch_add_explicit(&s->stats.device_frames_written,delivered,memory_order_relaxed);
 atomic_fetch_add_explicit(&s->stats.device_nonzero_samples_written,nonzero,memory_order_relaxed);
 if(delivered)atomic_store_explicit(&s->stats.device_write_host_time,mach_absolute_time(),memory_order_relaxed);
 if(unavailable||!frames){atomic_fetch_add_explicit(&s->stats.unavailable_output_buffers,1,memory_order_relaxed);atomic_store_explicit(&s->stats.peak,0,memory_order_relaxed);atomic_store_explicit(&s->stats.rms,0,memory_order_relaxed);}
 return noErr;
}
OSStatus ar_source_start_device(ar_source *s,AudioDeviceID device){s->device=device;OSStatus e=AudioDeviceCreateIOProcID(device,capture_proc,s,&s->io);if(e)return e;e=AudioDeviceStart(device,s->io);if(e){AudioDeviceDestroyIOProcID(device,s->io);s->io=NULL;}return e;}
OSStatus ar_sink_start_device(ar_sink *s,AudioDeviceID device){s->device=device;OSStatus e=AudioDeviceCreateIOProcID(device,playback_proc,s,&s->io);if(e)return e;e=AudioDeviceStart(device,s->io);if(e){AudioDeviceDestroyIOProcID(device,s->io);s->io=NULL;}return e;}
static void wait_block(uint64_t *deadline,double rate,uint32_t n){mach_timebase_info_data_t t;mach_timebase_info(&t);*deadline+=(uint64_t)(1e9*n/rate*t.denom/t.numer);mach_wait_until(*deadline);if(mach_absolute_time()>*deadline+((uint64_t)1e9*t.denom/t.numer))*deadline=mach_absolute_time();}
static void *writer_thread(void *p){pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);pthread_setname_np("AudioRoute mix");ar_sink *s=p;uint64_t deadline=mach_absolute_time();while(atomic_load(&s->running)){if(atomic_load(&s->active)){ar_sink_render(s,s->scratch,256);uint32_t n=s->writer(s->context,s->scratch,256);if(n<256)atomic_fetch_add(&s->stats.overruns,1);}wait_block(&deadline,s->rate,256);}return NULL;}
static void *reader_thread(void *p){pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);pthread_setname_np("AudioRoute capture");ar_source *s=p;uint64_t deadline=mach_absolute_time();while(atomic_load(&s->running)){if(atomic_load(&s->active)){uint32_t n=s->reader(s->context,s->scratch,256);if(n)ar_source_push(s,s->scratch,n);}wait_block(&deadline,s->rate,256);}return NULL;}
OSStatus ar_sink_start_writer(ar_sink *s,ar_write_fn fn,void *context){s->writer=fn;s->context=context;atomic_store(&s->running,true);int e=pthread_create(&s->thread,NULL,writer_thread,s);s->threaded=!e;return e;}
OSStatus ar_source_start_reader(ar_source *s,ar_read_fn fn,void *context){s->reader=fn;s->context=context;atomic_store(&s->running,true);int e=pthread_create(&s->thread,NULL,reader_thread,s);s->threaded=!e;return e;}
void ar_source_set_active(ar_source *s,bool active){atomic_store(&s->active,active);}
void ar_sink_set_active(ar_sink *s,bool active){atomic_store(&s->active,active);}
void ar_source_stop(ar_source *s){if(!s)return;if(s->threaded){atomic_store(&s->running,false);pthread_join(s->thread,NULL);s->threaded=false;}if(s->io){AudioDeviceStop(s->device,s->io);AudioDeviceDestroyIOProcID(s->device,s->io);s->io=NULL;}}
void ar_sink_stop(ar_sink *s){if(!s)return;if(s->threaded){atomic_store(&s->running,false);pthread_join(s->thread,NULL);s->threaded=false;}if(s->io){AudioDeviceStop(s->device,s->io);AudioDeviceDestroyIOProcID(s->device,s->io);s->io=NULL;}}
void ar_source_destroy(ar_source *s){if(!s)return;ar_source_stop(s);free(s->scratch);free(s);}
void ar_sink_destroy(ar_sink *s){if(!s)return;ar_sink_stop(s);for(uint32_t i=0;i<s->count;i++){ar_ring *r=s->routes[i].ring;free(r->samples);free(r);free(s->routes[i].matrix);}free(s->scratch);free(s);}
static ar_stats stats(counters *c){return(ar_stats){atomic_load(&c->callbacks),atomic_load(&c->frames),atomic_load(&c->last),atomic_load(&c->underruns),atomic_load(&c->overruns),atomic_load(&c->clips),atomic_load(&c->invalid),atomic_load(&c->device_frames_written),atomic_load(&c->device_nonzero_samples_written),atomic_load(&c->unavailable_output_buffers),atomic_load(&c->device_write_host_time),atomic_load(&c->peak),atomic_load(&c->rms)};}
ar_stats ar_source_stats(ar_source *s){return stats(&s->stats);}
ar_stats ar_sink_stats(ar_sink *s){return stats(&s->stats);}
