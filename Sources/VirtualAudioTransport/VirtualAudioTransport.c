#include "VirtualAudioTransport.h"
#include <stdatomic.h>
#include <xpc/xpc.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#define AR_MAGIC 0x41525431u
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit ring counters must be lock-free");
typedef struct {
    _Atomic uint64_t written, read;
    float samples[AR_TRANSPORT_CAPACITY * AR_TRANSPORT_MAX_CHANNELS];
} ar_ring;
typedef struct {
    _Atomic uint32_t magic;
    uint32_t version, input_channels, output_channels;
    _Atomic uint64_t underruns, overruns, driver_callbacks, driver_host_time, input_read_host_time;
    _Atomic uint32_t active_clients, driver_pid;
    ar_ring input, output;
} ar_shared;
struct ar_transport { ar_shared *shared; uint32_t input, output; };
ar_transport *ar_transport_open(const char *path, uint32_t input, uint32_t output, int create) {
    if (!path || input > 32 || output > 32 || !(input || output)) { errno = EINVAL; return NULL; }
    int flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC;
    int fd = open(path, flags | (create ? O_CREAT | O_EXCL : 0), 0660);
    int fresh = create && fd >= 0;
    if (fd < 0 && create && errno == EEXIST) fd = open(path, flags);
    if (fd < 0) return NULL;
    struct stat st;
    if (fresh && (fchmod(fd, 0660) || ftruncate(fd, sizeof(ar_shared)))) { close(fd); return NULL; }
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || (st.st_mode & 0007) || st.st_size != sizeof(ar_shared)) { close(fd); errno = EINVAL; return NULL; }
    ar_shared *s = mmap(NULL, sizeof(*s), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (s == MAP_FAILED) return NULL;
    if (fresh) {
        memset(s, 0, sizeof(*s)); s->version = AR_TRANSPORT_VERSION;
        s->input_channels = input; s->output_channels = output;
        atomic_store_explicit(&s->magic, AR_MAGIC, memory_order_release);
    }
    if (atomic_load_explicit(&s->magic, memory_order_acquire) != AR_MAGIC || s->version != AR_TRANSPORT_VERSION || s->input_channels != input || s->output_channels != output) {
        munmap(s, sizeof(*s)); errno = EINVAL; return NULL;
    }
    ar_transport *t = malloc(sizeof(*t));
    if (!t) { munmap(s, sizeof(*s)); return NULL; }
    t->shared = s; t->input=input; t->output=output; return t;
}
void ar_transport_close(ar_transport *t) { if (t) { munmap(t->shared, sizeof(ar_shared)); free(t); } }
static uint32_t write_ring(ar_transport *t, ar_ring *r, uint32_t ch, const float *data, uint32_t frames) {
    if (!ch || !data) return 0;
    uint64_t w = atomic_load_explicit(&r->written, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->read, memory_order_acquire);
    uint64_t pending = w - rd;
    uint32_t available = pending < AR_TRANSPORT_CAPACITY ? AR_TRANSPORT_CAPACITY - (uint32_t)pending : 0;
    uint32_t n = frames < available ? frames : available;
    for (uint32_t i = 0; i < n; ++i) memcpy(r->samples + ((w + i) % AR_TRANSPORT_CAPACITY) * ch, data + i * ch, ch * sizeof(float));
    atomic_store_explicit(&r->written, w + n, memory_order_release);
    if (n < frames) atomic_fetch_add_explicit(&t->shared->overruns, 1, memory_order_relaxed);
    return n;
}
static uint32_t read_ring(ar_transport *t, ar_ring *r, uint32_t ch, float *data, uint32_t frames) {
    if (!ch || !data) return 0;
    uint64_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->written, memory_order_acquire);
    uint64_t pending = w - rd;
    uint32_t available = pending < AR_TRANSPORT_CAPACITY ? (uint32_t)pending : AR_TRANSPORT_CAPACITY;
    uint32_t n = frames < available ? frames : available;
    for (uint32_t i = 0; i < n; ++i) memcpy(data + i * ch, r->samples + ((rd + i) % AR_TRANSPORT_CAPACITY) * ch, ch * sizeof(float));
    if (n < frames) { memset(data + n * ch, 0, (frames - n) * ch * sizeof(float)); atomic_fetch_add_explicit(&t->shared->underruns, 1, memory_order_relaxed); }
    atomic_store_explicit(&r->read, rd + n, memory_order_release); return n;
}
uint32_t ar_transport_write_input(ar_transport *t,const float *d,uint32_t n) { return t ? write_ring(t,&t->shared->input,t->input,d,n) : 0; }
uint32_t ar_transport_read_input(ar_transport *t,float *d,uint32_t n) { return t ? read_ring(t,&t->shared->input,t->input,d,n) : 0; }
uint32_t ar_transport_write_output(ar_transport *t,const float *d,uint32_t n) { return t ? write_ring(t,&t->shared->output,t->output,d,n) : 0; }
uint32_t ar_transport_read_output(ar_transport *t,float *d,uint32_t n) { return t ? read_ring(t,&t->shared->output,t->output,d,n) : 0; }
void ar_transport_set_active_clients(ar_transport *t,uint32_t n) { if (t) atomic_store(&t->shared->active_clients,n); }
void ar_transport_driver_callback(ar_transport *t,uint64_t h,uint32_t pid) { if (t) { atomic_fetch_add(&t->shared->driver_callbacks,1); atomic_store(&t->shared->driver_host_time,h); atomic_store(&t->shared->driver_pid,pid); } }
void ar_transport_get_stats(ar_transport *t,ar_transport_stats *o) {
    if (!o) return; memset(o,0,sizeof(*o)); if (!t) return; ar_shared *s=t->shared;
    o->input_frames_written=atomic_load(&s->input.written); o->input_frames_read=atomic_load(&s->input.read);
    o->output_frames_written=atomic_load(&s->output.written); o->output_frames_read=atomic_load(&s->output.read);
    o->underruns=atomic_load(&s->underruns); o->overruns=atomic_load(&s->overruns); o->driver_callbacks=atomic_load(&s->driver_callbacks); o->driver_host_time=atomic_load(&s->driver_host_time);
    o->active_clients=atomic_load(&s->active_clients); o->driver_pid=atomic_load(&s->driver_pid); o->input_channels=t->input; o->output_channels=t->output; o->input_read_host_time=atomic_load(&s->input_read_host_time);
}

void ar_transport_reset_input_reader(ar_transport *t) { if(t) atomic_store_explicit(&t->shared->input.read,atomic_load_explicit(&t->shared->input.written,memory_order_acquire),memory_order_release); }
uint32_t ar_transport_write_input_live(void *t,const float *d,uint32_t n) {
    ar_transport *transport=t;
    if(!transport) return 0;
    if(!atomic_load_explicit(&transport->shared->active_clients,memory_order_acquire)) return n;
    return ar_transport_write_input(transport,d,n);
}
uint32_t ar_transport_read_output_callback(void *t,float *d,uint32_t n) {
    ar_transport *transport=t; if(!transport) return 0;
    if(!atomic_load_explicit(&transport->shared->active_clients,memory_order_acquire)) {
        if(d) memset(d,0,(size_t)n*transport->output*sizeof(float));
        return 0;
    }
    return ar_transport_read_output(transport,d,n);
}

void *ar_transport_export_shared_memory(ar_transport *t) { return t ? xpc_shmem_create(t->shared,sizeof(ar_shared)) : NULL; }
ar_transport *ar_transport_import_shared_memory(void *object,uint32_t input,uint32_t output) {
    if(input>AR_TRANSPORT_MAX_CHANNELS||output>AR_TRANSPORT_MAX_CHANNELS||!(input||output)||!object||xpc_get_type(object)!=XPC_TYPE_SHMEM) {errno=EINVAL;return NULL;}
    void *region=NULL;size_t length=xpc_shmem_map(object,&region);
    if(length<sizeof(ar_shared)) {if(length)munmap(region,length);errno=EINVAL;return NULL;}
    ar_shared *s=region;
    if(atomic_load_explicit(&s->magic,memory_order_acquire)!=AR_MAGIC||s->version!=AR_TRANSPORT_VERSION||s->input_channels!=input||s->output_channels!=output) {munmap(region,length);errno=EINVAL;return NULL;}
    ar_transport *t=malloc(sizeof(*t));if(!t){munmap(region,length);return NULL;}t->shared=s;t->input=input;t->output=output;return t;
}

void ar_transport_input_read_callback(ar_transport *t,uint64_t h){if(t)atomic_store(&t->shared->input_read_host_time,h);}
