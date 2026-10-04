# AudioRoute HAL plug-in

This original C implementation targets Apple's public `AudioServerPlugIn` ABI.
It publishes dynamically named microphone, speaker and duplex devices with stable
UIDs (`org.audioroute.virtual.<id>`), one interleaved float32 stream per direction,
1–32 channels, and a fixed registry-selected rate (44.1, 48 or 96 kHz).

## Build and verification

```sh
scripts/build-driver.sh
scripts/test-driver.sh
```

The build produces `build/AudioRoute.driver` for arm64 and x86_64, with an ad-hoc
signature by default. Set `AUDIOROUTE_SIGN_IDENTITY` to a valid Developer ID
identity for distribution signing. Notarization is a separate distribution step.

The sanitizer harness invokes the real HAL vtable through a mock host. It checks
dynamic publication/removal/reappearance, stable UID and stream format, clock
mapping, client statistics, identical PCM for clients reading the same timestamps,
duplex delivery, queue saturation, silence on underrun, idle producer discard,
and XPC shared-memory boxing/mapping. It never installs or loads a system driver.
After explicit installation and activation, `scripts/test-live-driver.sh` creates temporary microphone and duplex endpoints and tests actual AudioDeviceIOProc capture with two clients, plus duplex output delivery. It sends known PCM only to virtual endpoints and removes those endpoints afterward. Physical audio and application selector checks remain separate.

## Installation

```sh
sudo scripts/install-driver.sh
```

The installer copies the bundle into `/Library/Audio/Plug-Ins/HAL`, installs
`org.audioroute.transport.plist` into `/Library/LaunchDaemons`, and creates
`/Library/Application Support/AudioRoute` and `devices` owned by the installing
user with group `_coreaudiod` and mode 2750. Reboot to load the broker and driver, or run `sudo scripts/activate-driver.sh --yes` to load the broker and restart Core Audio immediately. That activation interrupts current audio sessions.
The script deliberately leaves existing audio sessions running. To uninstall,
remove the driver and launch daemon as administrator, then reboot; retain or
remove the application-support data according to the user's intent.

## Control and audio contract

The routing daemon owns `registry.plist` (0640) and `devices/<id>.shm` (0660).
Publish the registry atomically only after each mapping has been initialized:

```json
{"devices":[{"id":"lesson-send","name":"Lesson Send","inputChannels":2,"outputChannels":0,"sampleRate":48000}]}
```

Serialize this structure as an XML or binary property list. IDs contain only
lowercase ASCII letters, digits and hyphens and fit in 127 bytes. Names are UTF-8.
Channel layout, name and sample rate are immutable for a published identity;
create a new identity when those parameters change. Device list changes are
observed within roughly one second. Removed objects retain their storage until
the HAL host exits, preventing outstanding callback references from dangling;
there are at most 128 identities per host lifetime.

The HAL host is sandboxed and **does not access these files**. A system-domain
XPC broker runs as `_coreaudiod`, validates connecting peers against that UID,
reads the fixed registry, and exports only the named device mappings using XPC
shared-memory handles. The plug-in declares `AudioServerPlugIn_MachServices` and
uses a system-domain Mach connection. All parsing, file access and XPC happen on
control queues. Audio callbacks use only preallocated sample-time caches and
memory-mapped rings. Clients reading the same time range receive the same PCM.

`VirtualAudioTransport.h` defines the C interface shared with the Swift engine.
Input means microphone from the application perspective: router writes, HAL
reads. Output means application speaker: HAL writes its complete mix, router
reads. Each direction requires a single producer and consumer; the daemon must
combine scenarios before writing a shared destination, or reject duplicate
writers. `ar_transport_write_input_live` discards while no HAL client runs;
`ar_transport_read_output_callback` zero-fills while idle without counting an
underrun. Overfull rings drop new frames; shortages produce silence. Ring files
persist across daemon restart and are not recreated while the driver retains a
mapping.

Active-client statistics count clients that have called StartIO on the device.
On an input-only endpoint this indicates active consumers. On duplex endpoints,
a client could be producing output, consuming input, or both, so it does not
prove which direction an application is using.

No BlackHole or other third-party audio driver source was copied. The contract
comes from the installed Apple SDK `CoreAudio/AudioServerPlugIn.h` and Apple's
[Audio Server Driver documentation](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in).
