#ifndef AUDIO_ROUTE_TRANSPORT_H
#define AUDIO_ROUTE_TRANSPORT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define AR_TRANSPORT_VERSION 2
#define AR_TRANSPORT_MAX_CHANNELS 32
#define AR_TRANSPORT_CAPACITY 16384
#ifndef AR_SHARED_DIRECTORY
#define AR_SHARED_DIRECTORY "/Library/Application Support/AudioRoute"
#endif
typedef struct ar_transport ar_transport;
typedef struct {
    uint64_t input_frames_written, input_frames_read, output_frames_written, output_frames_read;
    uint64_t underruns, overruns, driver_callbacks, driver_host_time, input_read_host_time;
    uint32_t active_clients, input_channels, output_channels, driver_pid;
} ar_transport_stats;
/* Control-plane only. Returns NULL and sets errno on failure. Existing files must match channels.
 * create: initialize a new mapping if absent; never resets existing audio/counters. */
ar_transport *ar_transport_open(const char *path, uint32_t input_channels, uint32_t output_channels, int create);
void ar_transport_close(ar_transport *transport);
/* Control-plane XPC boxed memory; caller releases exported xpc_object_t.
 * Kept opaque so Swift callers need not import XPC types. */
void *ar_transport_export_shared_memory(ar_transport *transport);
ar_transport *ar_transport_import_shared_memory(void *object, uint32_t input_channels, uint32_t output_channels);
/* Consumer only, before starting IO. Discards samples queued while idle. */
void ar_transport_reset_input_reader(ar_transport *transport);
/* ABI-compatible callback adapters; live input discards while no HAL client runs. */
uint32_t ar_transport_write_input_live(void *, const float *, uint32_t frames);
uint32_t ar_transport_read_output_callback(void *, float *, uint32_t frames);
/* Audio-plane: single producer/single consumer per direction, interleaved float PCM.
 * Input means app microphone: router writes, HAL reads. Read zero-fills shortages.
 * Functions never allocate, block, do file I/O or call the OS. Writes drop new excess frames.
 * The return value is frames copied (excluding zero padding). */
uint32_t ar_transport_write_input(ar_transport *, const float *, uint32_t frames);
uint32_t ar_transport_read_input(ar_transport *, float *, uint32_t frames);
uint32_t ar_transport_write_output(ar_transport *, const float *, uint32_t frames);
uint32_t ar_transport_read_output(ar_transport *, float *, uint32_t frames);
void ar_transport_get_stats(ar_transport *, ar_transport_stats *);
void ar_transport_set_active_clients(ar_transport *, uint32_t clients);
void ar_transport_driver_callback(ar_transport *, uint64_t host_time, uint32_t driver_pid);
void ar_transport_input_read_callback(ar_transport *, uint64_t host_time);
#ifdef __cplusplus
}
#endif
#endif
