#ifndef AUDIO_ROUTE_RT_H
#define AUDIO_ROUTE_RT_H
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
#define AR_MAX_CHANNELS 64
#define AR_MAX_ROUTES 64
#define AR_RING_FRAMES 16384
#define AR_BLOCK_FRAMES 4096

typedef struct ar_source ar_source;
typedef struct ar_sink ar_sink;
typedef struct {
 uint64_t callbacks, frames, last_host_time, underruns, overruns, clipped_samples, invalid_samples;
 uint64_t device_frames_written, device_nonzero_samples_written, unavailable_output_buffers, device_write_host_time;
 float peak, rms;
} ar_stats;
typedef uint32_t (*ar_write_fn)(void *context, const float *samples, uint32_t frames);
typedef uint32_t (*ar_read_fn)(void *context, float *samples, uint32_t frames);

ar_source *ar_source_create(uint32_t channel_count, const uint32_t *channel_indices, double rate);
void ar_source_destroy(ar_source *source);
ar_sink *ar_sink_create(uint32_t channel_count, const uint32_t *channel_indices, double rate, float ceiling);
void ar_sink_destroy(ar_sink *sink);
// Configuration must be completed before any source or sink starts.
bool ar_sink_add_route(ar_sink *sink, ar_source *source, const float *matrix);
OSStatus ar_source_start_device(ar_source *source, AudioDeviceID device);
OSStatus ar_sink_start_device(ar_sink *sink, AudioDeviceID device);
OSStatus ar_source_start_reader(ar_source *source, ar_read_fn reader, void *context);
OSStatus ar_sink_start_writer(ar_sink *sink, ar_write_fn writer, void *context);
void ar_source_set_active(ar_source *source, bool active);
void ar_sink_set_active(ar_sink *sink, bool active);
void ar_source_stop(ar_source *source);
void ar_sink_stop(ar_sink *sink);
ar_stats ar_source_stats(ar_source *source);
ar_stats ar_sink_stats(ar_sink *sink);
// Public deterministic DSP entrypoints for offline tests, no allocations or locks.
void ar_source_push(ar_source *source, const float *interleaved, uint32_t frames);
void ar_sink_render(ar_sink *sink, float *interleaved, uint32_t frames);
#ifdef __cplusplus
}
#endif
#endif
