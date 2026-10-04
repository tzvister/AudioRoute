# CLI-First Virtual Audio Router for macOS

**Working name:** `audioroute`  
**Status:** Product / engineering brief  
**Primary audience:** Coding agents such as Codex, Claude Code, and developers implementing or operating the system  
**Platform:** macOS  
**Core idea:** A user describes the result they want in natural language. A coding agent uses a documented CLI to inspect the Mac, create virtual audio devices, build the routing graph, apply it, and verify that it is working. The user should not need to understand Core Audio, virtual devices, aggregate devices, taps, clocks, or channel maps.

---

## 1. Product goal

Build a macOS audio-routing system with the useful core of Rogue Amoeba Loopback, but **CLI-first and agent-friendly**.

The product should let an automation agent:

- discover physical audio devices and their channels;
- discover currently running audio-producing applications;
- create and remove named virtual audio devices;
- capture audio from individual applications;
- capture inputs from physical audio devices;
- mix, split, mute, gain-adjust, and channel-map audio;
- provide an independent volume control for every input/source;
- provide an independent volume control for every output/destination, including gain above unity (> 0 dB / louder than 100%);
- send a mix into a virtual Core Audio input that apps such as Zoom, Google Meet, OBS, Discord, Teams, or a DAW can select;
- send any mix to one or more physical or virtual outputs;
- keep all destination-specific mixes together inside one named scenario;
- persist the configuration;
- survive application restarts and device disconnect/reconnect where possible;
- report whether the route is actually live;
- expose all operations through deterministic, documented, machine-readable CLI commands.

The **user-facing abstraction is intent**, not audio plumbing.


### Core routing semantics

The user-facing model is scenario-centric:

```text
scenario -> inputs + outputs
                 |
                 +-> each output owns its own input mix
```

There is **no separate user-facing “monitor” concept**.

An output is simply a destination for some mix. It may be:

- a physical output such as AirPods or a USB interface;
- a virtual input consumed by Zoom/Meet/OBS;
- a virtual output/pass-through endpoint;
- another internal bus.

Every input may have a source-wide trim. More importantly, every output owns an independent mix with a separate level for each input, plus its own master output gain.

Output gain may exceed unity:

```text
-12 dB   quieter
  0 dB   unity / 100%
 +6 dB   boosted above 100%
```

Positive gain is legal. The router should warn or limit if clipping occurs, but must not artificially cap output gain at 100%.


Physical endpoints are hot-pluggable. If an input or output disappears, the graph remains alive:

```text
missing input  -> silence from that input
missing output -> audio for that output is discarded
reconnected    -> route resumes automatically
```

A temporary disconnect is a **degraded runtime state**, not a graph error.


A user should be able to tell an agent:

> “I’m taking a remote guitar lesson. Send my guitar interface and my voice mic to Zoom. I’m listening on AirPods. I want to hear the guitar and my teacher in the AirPods, but I don’t want to hear my own voice.”

The agent should be able to turn that into a working scenario without asking the user to understand the routing.

---

## 2. What Loopback actually provides

Loopback is more than a virtual audio cable. The useful routing model for this project is:

```text
Sources -> channel mapping / mixer -> outputs
```

A source can be:

- an application;
- a physical audio device;
- another audio source;
- a pass-through input.

A Loopback virtual device can appear to macOS as an audio input, and with pass-through enabled it can also appear as an audio output. Loopback lets source channels be mapped to arbitrary virtual-device channels. Loopback exposes a separate monitor concept, but this project should **not** expose that concept to users or coding agents. A physical playback destination is simply another output of a mix, exactly like a virtual destination.

For the CLI product, the important concepts to reproduce are:

1. **Application capture**
2. **Physical-device input**
3. **Virtual audio endpoints**
4. **Mixing and channel mapping**
5. **Independent input level controls**
6. **Independent output level controls, including gain above unity**
7. **Multiple outputs per mix**
8. **Pass-through when required**
9. **Persistent named configurations**
10. **Low-latency real-time operation**

We do **not** need to reproduce Loopback’s GUI to reproduce its audio-routing capabilities.

References:

- Loopback Sources: https://www.rogueamoeba.com/support/manuals/loopback/?page=sources
- Loopback Output Channels: https://www.rogueamoeba.com/support/manuals/loopback/?page=outputchannels
- Loopback Monitors: https://www.rogueamoeba.com/support/manuals/loopback/?page=monitors
- Loopback Pass-Thru: https://www.rogueamoeba.com/support/manuals/loopback/?page=passthru

---

## 3. We do not need BlackHole as a product dependency

BlackHole is useful as:

- a reference implementation;
- a prototype endpoint;
- a way to validate the mixer before the custom virtual-device driver exists.

It is **not required** for the final product.

macOS provides the primitives needed to build our own virtual audio devices.

Apple provides:

- a sample for creating a virtual audio device with an **Audio Server Driver Plug-in**;
- a newer sample combining an **Audio Server Plug-in and Driver Extension**;
- a dynamic sample environment capable of supporting **multiple audio devices**.

This is the layer that should eventually expose devices such as:

```text
Guitar Lesson Send
Podcast Mix
Streaming Mic
Music Bus
Game Chat
```

to macOS and to applications.

Apple references:

- Creating an Audio Server Driver Plug-in:  
  https://developer.apple.com/documentation/CoreAudio/creating-an-audio-server-driver-plug-in
- Building an Audio Server Plug-in and Driver Extension:  
  https://developer.apple.com/documentation/CoreAudio/building-an-audio-server-plug-in-and-driver-extension

BlackHole is still valuable as engineering reference material:

- https://github.com/ExistentialAudio/BlackHole

BlackHole is GPLv3. Its project explicitly requires a separate license for non-GPLv3 projects. Do not copy BlackHole source into a differently licensed product without resolving licensing.

---

## 4. The three technical layers

The architecture naturally separates into three layers.

### 4.1 Capture

Get audio from applications and physical devices.

For application audio, use **Core Audio Process Taps**.

Apple introduced process taps in macOS 14.2. A tap can capture outgoing audio from one process or a group of processes. A tap can also mute the process’s original output, allowing the router to take over playback.

This removes the need for a proprietary capture driver for modern macOS.

Apple documentation:

https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

For physical inputs, use normal Core Audio device input streams.

Examples:

```text
USB guitar interface input 1
USB interface microphone input 2
MacBook microphone
USB microphone
```

### 4.2 Routing / mixing

A real-time engine receives audio from all active sources and applies:

- channel mapping;
- per-input volume / gain;
- mute;
- summing;
- fan-out;
- per-output volume / gain, including positive gain above unity;
- multiple independent outputs from the same mix;
- optional sample-rate conversion;
- optional limiting to prevent clipping.

Internally, use 32-bit floating-point PCM.

The core operation is conceptually:

```text
destination[channel][frame] +=
    source[sourceChannel][frame] * gain * routeWeight
```

The mixer itself is not the difficult part. The difficult parts are:

- clock synchronization;
- real-time safety;
- device changes;
- process restarts;
- sample-rate changes;
- Bluetooth devices;
- reconnecting hardware;
- permissions;
- avoiding glitches during graph changes.

### 4.3 Delivery

Expose the resulting mix to other applications as a **real Core Audio virtual device**.

Examples:

```text
"Guitar Lesson Send"    -> appears as a microphone/input
"Podcast Mix"           -> appears as an input
"App Pass-Thru"         -> appears as input + output
```

The virtual-device driver exchanges audio with the routing daemon using a real-time-safe mechanism such as shared memory and lock-free ring buffers.

---

## 5. Recommended architecture

```text
                         macOS applications
                    +--------------------------+
                    | Zoom / Meet / Spotify    |
                    | Browser / DAW / Discord  |
                    +-------------+------------+
                                  |
                    Core Audio Process Taps
                                  |
                                  v
+----------------+       +---------------------+       +------------------+
| USB interface  | ----> |                     | ----> | Virtual devices  |
| microphones    |       |    audiorouted      |       | exposed to macOS |
| other inputs   | ----> |                     |       +------------------+
+----------------+       | realtime mixer      |
                         | channel matrix       |
                         | resampling / clocks  |
                         | health / meters      |
                         +----------+-----------+
                                    |
                                    v
                         +----------------------+
                         | physical outputs     |
                         | AirPods              |
                         | headphones           |
                         | built-in speakers    |
                         | USB interface output |
                         +----------------------+

                              ^
                              |
                         local IPC / XPC
                              |
                         +----+-----+
                         | audioroute |
                         | CLI        |
                         +------------+
```

### Processes

**`audiorouted`**

Long-running background service responsible for:

- Core Audio graph ownership;
- taps;
- physical device I/O;
- real-time mixer;
- virtual-device communication;
- persistence;
- device/app lifecycle monitoring;
- meters and health information.

**`audioroute`**

Thin CLI responsible for:

- discovery;
- configuration;
- validation;
- applying graphs;
- status;
- diagnostics;
- structured output for coding agents.

The CLI should **not** own the long-running real-time audio graph.

This matters for reliability and macOS permissions. System-audio capture permission should belong to one stable application/service rather than whichever terminal happens to launch a CLI command.

---

## 6. Why a daemon is important

A CLI process that opens taps and devices directly would be fragile.

The daemon gives us:

- stable System Audio Recording permission;
- stable microphone permission;
- routes that continue after the shell exits;
- automatic recovery after app restarts;
- automatic recovery after USB devices reconnect;
- a single owner for Core Audio callbacks;
- atomic graph changes;
- persistent virtual devices;
- a clean control API for future GUI, MCP, or scripting clients.

The CLI should talk to the daemon using XPC or a local Unix-domain socket.

---

## 7. Core Audio Process Taps

Process taps are central to the project.

Apple’s documented flow is approximately:

```text
process
   |
CATapDescription
   |
AudioHardwareCreateProcessTap
   |
tap
   |
private aggregate device
   |
IO callback
   |
PCM
```

Apple’s sample shows that a tap can be used as an input in a private aggregate device, much like a microphone.

Important behavior:

- capture one process or a group of processes;
- capture system/application output without changing the application’s selected output device;
- optionally mute the original process output;
- mix down as required;
- permission is required;
- minimum supported macOS version is 14.2.

The product should identify applications using stable identifiers where possible, not only PIDs.

A route such as:

```text
app:us.zoom.xos
```

should automatically reattach if Zoom quits and relaunches.

Browser applications require special handling. Google Meet running inside Chrome may not always be uniquely distinguishable from unrelated Chrome audio using only an app-level identifier. The engine should expose what it can actually isolate and must not pretend tab-level isolation exists when it does not.

---

## 8. Virtual audio devices

The product should own its virtual-device layer.

### Required capabilities

A virtual device should be able to be:

- input-only;
- output-only;
- duplex;
- mono, stereo, or multichannel;
- dynamically named;
- dynamically created and deleted;
- independently addressable;
- persistent across daemon restart;
- visible in Audio MIDI Setup and normal application device selectors.

Terminology must be explicit because “input” and “output” become confusing.

Use the **Core Audio / application perspective**:

- **virtual input**: an application reads audio from it, like a microphone;
- **virtual output**: an application writes audio to it, like speakers.

Examples:

```text
Guitar Lesson Send
  Core Audio direction: input
  Router writes -> Zoom reads

App Return
  Core Audio direction: output
  Zoom writes -> Router reads
```

A duplex device supports both.

### Driver implementation

Start from Apple’s driver samples rather than inventing the HAL protocol from scratch.

The modern Apple sample supports a dynamic environment with multiple devices. Extend it for:

- arbitrary channel count;
- stable UIDs;
- runtime device creation/removal;
- configurable names;
- format negotiation;
- daemon communication;
- active-client reporting;
- ring buffers.

Real-time driver code must not:

- allocate memory;
- take blocking locks;
- perform file I/O;
- log synchronously;
- call network services;
- wait on the daemon.

---

## 9. Agent-first CLI design

The CLI is primarily an API for coding agents.

Human readability is useful, but deterministic machine behavior is more important.

### Design rules

Every important command should support:

```text
--json
```

JSON output should have a stable schema.

Commands should have:

- deterministic exit codes;
- stable device IDs;
- stable application IDs;
- actionable errors;
- no interactive prompts by default;
- `--yes` for explicitly destructive operations;
- `--dry-run`;
- `validate`;
- idempotent `apply`;
- atomic scenario updates;
- a way to export current state.

A coding agent must be able to answer:

1. What devices exist?
2. What inputs and outputs do they have?
3. Which apps are currently producing audio?
4. What permissions are missing?
5. Can the requested scenario be built?
6. What did the tool change?
7. Is audio actually flowing?
8. Is the target application consuming the virtual device?
9. Is anything clipping or disconnected?
10. What user action, if any, remains?

---

## 10. Recommended CLI surface

The names below are illustrative but define the desired semantics.

### Discover

```bash
audioroute devices list
audioroute devices inspect <device-id>
audioroute apps list
audioroute apps playing
audioroute permissions
audioroute virtual list
```

Examples:

```bash
audioroute devices list --json
audioroute apps playing --json
```

A physical device result should include:

```json
{
  "id": "coreaudio:device:ABC123",
  "name": "USB Audio Interface",
  "transport": "usb",
  "input_channels": 4,
  "output_channels": 4,
  "sample_rates": [44100, 48000, 96000],
  "current_sample_rate": 48000,
  "connected": true
}
```

An application result should include:

```json
{
  "id": "app:us.zoom.xos",
  "name": "zoom.us",
  "bundle_id": "us.zoom.xos",
  "audio_active": true,
  "processes": [12345]
}
```

### Virtual devices

```bash
audioroute virtual create "Lesson Send" --input 2 --output 0
audioroute virtual create "Pass Through" --input 2 --output 2
audioroute virtual delete lesson-send
audioroute virtual inspect lesson-send
```

### Scenarios

A scenario is the primary unit a coding agent creates, applies, verifies, and removes.

```bash
audioroute scenario list
audioroute scenario show guitar-lesson
audioroute scenario validate guitar-lesson.yaml
audioroute scenario apply guitar-lesson.yaml
audioroute scenario verify guitar-lesson
audioroute scenario delete guitar-lesson
audioroute scenario export guitar-lesson
```

Internally the implementation may still call this an audio graph, but `scenario` is the user-facing CLI term.


### Runtime

```bash
audioroute status
audioroute status guitar-lesson
audioroute meter guitar-lesson
audioroute doctor
audioroute doctor guitar-lesson
```


### Levels

There are three distinct level controls:

1. **Input trim** — a source-wide adjustment applied before it reaches any output.
2. **Per-output input level** — the level of one input specifically within one output's mix.
3. **Output master gain** — the final level of that output.

Examples:

```bash
# Source-wide trim
audioroute level set scenario:guitar-lesson input:guitar --db -2

# Guitar level only in the teacher/Zoom output
audioroute level set scenario:guitar-lesson output:teacher input:guitar --db -6

# The same guitar can be louder in the AirPods output
audioroute level set scenario:guitar-lesson output:airpods input:guitar --db 3

# Master gain for the AirPods output
audioroute level set scenario:guitar-lesson output:airpods --master-db 2
```

Semantics:

- `0 dB` = unity;
- negative dB attenuates;
- positive dB boosts above unity / above 100%;
- `mute` is distinct from an arbitrarily low gain value;
- dB is canonical even if the CLI also offers a percentage convenience form;
- every output keeps its own independent per-input levels;
- changing an input's level in one output must not change that input's level in any other output;
- output master gain may be positive, while clipping risk is surfaced through meters and optional limiting.


### Optional imperative graph editing

Useful for debugging, but not the main agent interface:

```bash
audioroute bus create teacher-send --channels 2
audioroute connect ...
audioroute disconnect ...
audioroute gain ...
audioroute mute ...
```

---

## 11. Prefer declarative configuration

For coding agents, a declarative spec is better than a long sequence of imperative commands.

The desired workflow is:

```bash
audioroute inspect --json
audioroute scenario validate /tmp/guitar-lesson.yaml
audioroute scenario apply /tmp/guitar-lesson.yaml
audioroute status guitar-lesson --json
```

`apply` should be idempotent.

Running it twice should result in the same graph, not duplicate routes.

A configuration should be validated completely before the live scenario is changed.

If an apply fails, the previous known-working scenario should remain active.

---

## 12. Proposed configuration model

The configuration file represents one complete scenario.

The agent should not need to expose internal buses unless it is debugging. Each output declares the mix it wants from the scenario's inputs.

Example:

```yaml
version: 1

scenario:
  id: guitar-lesson
  name: Guitar Lesson
  target_sample_rate: 48000
  latency_mode: low

inputs:
  guitar:
    type: device_input
    device: coreaudio:device:USB_INTERFACE_UID
    channels: [1]
    trim_db: 0

  voice:
    type: device_input
    device: coreaudio:device:VOICE_MIC_UID
    channels: [1]
    trim_db: 0

  teacher:
    type: application_output
    application: app:us.zoom.xos
    channels: [1, 2]
    mute_original: true
    trim_db: 0

outputs:
  teacher-send:
    name: Guitar Lesson Send
    type: virtual_input
    channels: 2
    master_gain_db: 0

    mix:
      guitar:
        gain_db: -3
        map: mono_to_stereo

      voice:
        gain_db: 0
        map: mono_to_stereo

      teacher:
        mute: true

  airpods:
    name: AirPods
    type: device_output
    device: coreaudio:device:AIRPODS_UID
    channels: [1, 2]
    master_gain_db: 2

    mix:
      guitar:
        gain_db: 3
        map: mono_to_stereo

      voice:
        mute: true

      teacher:
        gain_db: -6
        map: stereo

policy:
  reconnect: true
  disconnected_input: silence
  disconnected_output: discard
  clip_protection: true
  limiter_ceiling_dbfs: -1
```

The important semantic rule is:

> **Input levels are destination-specific.**

Changing `guitar` from `-3 dB` to `-8 dB` in `teacher-send` must not change the `+3 dB` guitar level in `airpods`.

The source-wide `trim_db` remains useful for correcting a consistently hot or quiet physical source, but normal “how much of this input goes to this output?” control belongs to the output's mix.


## 13. Guitar-lesson reference scenario

### User intent

The user has:

- a USB soundcard / guitar interface;
- one or more microphones;
- AirPods;
- Zoom, Google Meet, or a similar remote-call application.

Everything belongs to one scenario:

```text
Guitar Lesson
```

The scenario contains three logical inputs:

```text
Guitar
Voice
Teacher / call return
```

and two outputs:

```text
Teacher
Me
```

Each output has its own independent mix.

### Output: Teacher

```text
Guitar       -> teacher at chosen level
Voice        -> teacher at chosen level
Call return  -> muted
```

The teacher should not receive:

- the teacher's own return audio;
- unrelated Mac system audio;
- arbitrary browser audio;
- any source not explicitly included.

The output is delivered through a virtual Core Audio input such as:

```text
Guitar Lesson Send
```

which Zoom/Meet selects as its microphone.

### Output: Me

```text
Guitar       -> AirPods at independently chosen level
Voice        -> muted unless explicitly requested
Call return  -> AirPods at independently chosen level
```

The crucial point is that **Guitar does not have one global “volume” for the whole scenario**.

For example:

```text
Guitar -> Teacher:  -6 dB
Guitar -> Me:       +3 dB

Voice -> Teacher:    0 dB
Voice -> Me:         muted

Teacher Return -> Teacher: muted
Teacher Return -> Me:      -4 dB
```

Those are independent settings inside the same `Guitar Lesson` scenario.

This model scales naturally. One scenario can contain any number of inputs and outputs, and each output owns its own mix matrix.


## 14. Zoom / Meet selection limitation

The router can create a virtual microphone named:

```text
Guitar Lesson Send
```

but macOS does not provide a universal API that forces every third-party application to select a particular microphone.

Therefore the CLI should make this explicit and structured.

After applying a graph it may return:

```json
{
  "state": "ready",
  "requires_user_action": [
    {
      "application": "zoom.us",
      "action": "select_input_device",
      "device": "Guitar Lesson Send"
    }
  ]
}
```

A coding agent can then say only:

> “In Zoom, choose ‘Guitar Lesson Send’ as the microphone.”

Once the virtual device is opened by Zoom, the driver/daemon should be able to report that it has an active consumer.

For apps where reliable integration is available, automation may be added later. Do not make fragile UI automation a core dependency.

Google Meet has the same issue, usually inside a browser.

---

## 15. Routing Zoom or Meet return audio to an output

There are two strategies.

### Strategy A — simplest

Let Zoom output normally to the AirPods.

The router sends only the guitar mix to the AirPods.

macOS mixes both streams at the output device.

```text
Zoom --------------------> AirPods
guitar -> audiorouted ---> AirPods
```

Advantages:

- simpler;
- fewer taps;
- fewer failure modes.

Disadvantages:

- `audiorouted` does not control Zoom’s return level;
- strict per-app isolation and unified metering are weaker.

### Strategy B — router owns the complete AirPods output mix

Create a process tap for Zoom:

```text
Zoom -> tap -> mute original -> listening bus
guitar ----------------------> listening bus
                               |
                               v
                            AirPods
```

Advantages:

- exact local mix;
- independent Zoom gain;
- unified metering;
- no unintended Zoom output elsewhere.

Disadvantages:

- more complex;
- requires System Audio Recording permission;
- application lifecycle must be managed.

The CLI should support both.

For a sophisticated “make this exact workflow work” agent, Strategy B is the stronger abstraction.

---

## 16. Latency: “zero latency” needs precise language

The project should aim for **near-zero added software latency**, not claim zero end-to-end latency.

BlackHole describes itself as adding zero additional driver latency. That is useful terminology: a virtual driver can avoid adding deliberate buffering. It does not mean the complete audio path has zero latency.

Real-world latency comes from:

- USB interface buffers;
- Core Audio buffers;
- safety offsets;
- sample-rate conversion;
- mixer buffers;
- Bluetooth transmission;
- AirPods internal buffering;
- application processing.

### AirPods are the important constraint

AirPods are Bluetooth devices. They are not appropriate for genuinely zero-latency live instrument listening.

Even with an extremely efficient router:

```text
guitar -> USB interface -> Mac -> AirPods
```

will have audible Bluetooth latency compared with:

```text
guitar -> USB interface -> wired headphones
```

or a hardware direct headphone/output path.

The product should therefore distinguish:

```text
zero-added-latency routing
```

from:

```text
zero-latency listening
```

The latter cannot be guaranteed.

### CLI behavior

The CLI should detect risky output devices and report a warning:

```json
{
  "latency": {
    "mode": "low",
    "software_path": "optimized",
    "warnings": [
      {
        "code": "bluetooth_output",
        "message": "The selected output is Bluetooth. Real-time instrument listening will have unavoidable device latency."
      }
    ]
  }
}
```

A coding agent can then tell the user:

> “The routing is working. The remaining guitar-listening delay comes from the AirPods; use wired headphones or the interface’s headphone output for true low-latency playing.”

The system should not misrepresent Bluetooth listening as zero-latency.

---

## 17. Multiple clocks and drift

A common graph contains unrelated hardware clocks:

```text
USB input clock
AirPods output clock
```

These devices will not run at exactly the same rate forever, even if both report 48 kHz.

Without correction, a long-running route eventually experiences:

- under-runs;
- over-runs;
- clicks;
- dropped frames;
- growing latency.

The engine must handle asynchronous clocks.

Apple’s `AudioHardwareAggregateDevice` can combine devices and taps and synchronize its subdevices/subtaps while I/O is running.

Reference:

https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice

Implementation options include:

- Core Audio aggregate-device clock handling;
- drift correction;
- asynchronous sample-rate conversion between clock domains.

Clock handling is a first-class engineering concern, not an edge case.

---

## 18. Device disconnects must degrade to silence, not graph failure

Physical audio devices are transient.

USB interfaces, AirPods, USB microphones, docks, and other devices may disappear and reconnect at any time.

A graph must **not break** because one configured source or destination is temporarily unavailable.

Required behavior:

```text
connected device -> normal audio
device disconnects -> that endpoint becomes silent
device reconnects -> route automatically resumes
```

For a missing **input/source**:

- contribute silence to the graph;
- preserve all routing, gain, mute, and channel settings;
- report the source as `disconnected`;
- automatically reattach when the same stable device UID returns.

For a missing **output/destination**:

- discard audio destined for that output while it is unavailable;
- do not stop other outputs on the same graph;
- preserve output gain and routing state;
- automatically resume when the destination reconnects.

This is a runtime state, not a graph-validation error.

Example:

```json
{
  "graph": "guitar-lesson",
  "state": "running_degraded",
  "outputs": {
    "airpods": {
      "connected": false,
      "audio": "discarded_until_reconnect"
    },
    "lesson-send": {
      "connected": true,
      "audio": "active"
    }
  }
}
```

The daemon should surface the disconnection for diagnostics, but should not turn normal hot-plug behavior into an error.

A scenario should fail validation only when the specification itself is invalid, not because a previously known hardware endpoint happens to be unplugged at that moment.

## 19. Sample-rate handling

The product should prefer one internal rate per graph, normally:

```text
48 kHz
32-bit float
```

because 48 kHz is common for video calls and modern audio hardware.

However, devices may expose:

- 44.1 kHz;
- 48 kHz;
- 96 kHz;
- other rates.

The engine must either:

1. negotiate a common rate; or
2. resample safely.

A scenario validation result should say what it will do before applying:

```json
{
  "graph": "guitar-lesson",
  "internal_sample_rate": 48000,
  "conversions": [
    {
      "source": "USB Audio Interface",
      "from": 44100,
      "to": 48000
    }
  ]
}
```

---

## 20. AirPods-specific behavior

AirPods should be treated as a dynamic Bluetooth output, not as a fixed studio device.

Potential events include:

- disconnect/reconnect;
- switching between Mac/iPhone;
- sample-rate or format changes;
- increased latency;
- quality changes if the AirPods microphone is also activated.

For the guitar-lesson workflow, prefer a **separate voice microphone** rather than the AirPods microphone when possible.

The daemon should:

- watch for device disappearance;
- reconnect by stable UID/name;
- rebuild the output stream if format changes;
- surface the event rather than silently failing.

---

## 21. Application lifecycle handling

Routes should refer to applications by bundle identifier when possible.

Bad persistent identity:

```text
PID 91823
```

Better:

```text
app:us.zoom.xos
```

The daemon should watch the Core Audio process list.

When the application restarts:

1. detect the new process/audio object;
2. recreate or retarget the tap;
3. reconnect it to the same bus;
4. preserve gain and mute state;
5. report temporary degraded state if necessary.

Reference implementations worth studying:

### `catap`

https://github.com/sbetko/catap

Useful ideas:

- process enumeration;
- Core Audio process taps;
- private aggregate device;
- multiple synchronized app taps;
- tap retargeting;
- Core Audio change listeners;
- bounded queues;
- buffer/drop detection.

`catap` is a capture library, **not** a virtual driver or full router.

### AudioTee

https://github.com/makeusabrew/audiotee

Useful as a compact Swift example of:

- Core Audio tap capture;
- process include/exclude;
- process muting;
- PCM output.

### Fader

https://github.com/hatimhtm/Fader

Useful architectural reference for:

```text
application
 -> muted Core Audio tap
 -> private aggregate device
 -> gain/mix
 -> physical output
```

It demonstrates that modern per-app capture and rerendering can be done in user space without a third-party capture driver.

---

## 22. Permissions

Expect at least three categories of permission/setup.

### System Audio Recording

Required for Core Audio process taps.

Apps using taps should include:

```text
NSAudioCaptureUsageDescription
```

The first capture triggers the macOS permission flow.

### Microphone / audio-input permission

Required when reading microphone-like physical inputs, depending on the input and application context.

Include a clear usage description and treat denied permission as a structured error.

### Virtual driver installation

A virtual audio driver or Driver Extension will require a one-time installation/activation path.

Production distribution should be:

- signed;
- notarized;
- installable without asking users to disable system security;
- explicit about any macOS approval required.

The normal everyday CLI should not require `sudo`.

---

## 23. Real-time engineering rules

The audio callback path must be real-time safe.

Avoid inside a render/input callback:

- heap allocation;
- blocking locks;
- filesystem I/O;
- network I/O;
- synchronous logging;
- JSON encoding;
- IPC round trips;
- waiting for another thread.

Use:

- preallocated buffers;
- lock-free queues/ring buffers;
- atomic state where appropriate;
- immutable graph snapshots;
- graph swaps at safe buffer boundaries;
- background workers for control-plane work.

Control-plane and audio-plane code should be clearly separated.

---

## 24. Graph updates must be atomic

An agent will frequently change a live scenario.

Example:

```text
old:
guitar -> Zoom

new:
guitar + microphone -> Zoom
```

The router should not tear down the working scenario first and then attempt the new one.

Desired behavior:

1. parse new spec;
2. resolve all resources;
3. validate permissions;
4. validate devices;
5. validate formats;
6. build replacement graph;
7. start required resources;
8. atomically switch;
9. release old graph.

If step 1–7 fails, keep the old graph.

This is especially important for agent operation.

---

## 25. Verification is part of the product

“Configuration succeeded” is not enough.

The user’s requirement is:

> “It works.”

The CLI therefore needs runtime verification.

### `audioroute status`

Should report:

- scenario running;
- sources connected;
- app taps active;
- device streams active;
- virtual device published;
- virtual device consumer count;
- output device connected;
- current sample rate;
- buffer health;
- underrun/overrun count;
- clipping;
- recent reconnects;
- permission failures.

Example:

```json
{
  "graph": "guitar-lesson",
  "state": "running",
  "sources": {
    "guitar": {
      "connected": true,
      "signal": true,
      "peak_dbfs": -14.2
    },
    "voice": {
      "connected": true,
      "signal": true,
      "peak_dbfs": -21.8
    },
    "teacher": {
      "connected": true,
      "application_running": true,
      "signal": true
    }
  },
  "virtual_devices": {
    "lesson-send": {
      "published": true,
      "active_consumers": 1
    }
  },
  "outputs": {
    "airpods": {
      "device": "AirPods",
      "connected": true,
      "volume_db": 0
    },
    "lesson-send": {
      "connected": true,
      "volume_db": 0
    }
  },
  "xruns": 0
}
```

This allows an agent to distinguish:

```text
route created
```

from:

```text
route confirmed active
```

---

## 26. `doctor` command

A dedicated diagnostic command is important.

```bash
audioroute doctor
audioroute doctor guitar-lesson
```

It should check:

- daemon running;
- driver installed;
- virtual devices visible;
- permissions granted;
- sources present;
- sink present;
- supported sample rates;
- clock-domain issues;
- Bluetooth output latency warning;
- scenario validity;
- virtual-device consumers;
- audio callbacks advancing;
- underruns/overruns;
- signal present where expected.

Use machine-readable codes.

Example:

```json
{
  "ok": false,
  "issues": [
    {
      "code": "target_not_consuming_virtual_input",
      "severity": "action_required",
      "message": "No application is currently reading Guitar Lesson Send."
    }
  ]
}
```

A coding agent can translate that into a user-level instruction.

---

## 27. Metering

Minimal metering is extremely useful for automation.

Provide:

```bash
audioroute meter guitar-lesson --json
```

At minimum:

- peak dBFS;
- RMS;
- clipping;
- silence;
- per-source and per-bus levels.

This lets the agent verify:

- guitar is arriving;
- microphone is arriving;
- teacher return is arriving;
- the send mix is not clipping.

Meters should be implemented without compromising the real-time path.

---

## 28. Stable identity

Names are for people; UIDs are for persistence.

Every device should expose:

```text
display name
Core Audio UID
transport
vendor/product where available
channel layout
```

Configuration should persist using stable IDs, with names only as fallback.

If a configured device disappears:

```text
USB Audio Interface
```

and later returns with the same UID, the graph should recover automatically.

If only a name match is available and multiple devices match, the daemon should not guess.

Return an ambiguity error that the coding agent can resolve.

---

## 29. Declarative safety rules

An agent should be able to specify intent without accidentally making destructive global changes.

Default rules:

- do not change macOS default input/output unless explicitly requested;
- do not reroute unrelated applications;
- do not capture system-wide audio when a specific app was requested;
- do not include additional microphones automatically;
- do not route a microphone to a listening output unless requested;
- do not create feedback loops;
- do not persist a change outside the graph unless declared;
- do not emit test tones without explicit request.

A graph validator should detect feedback cycles.

---

## 30. Feedback protection

Virtual routing can accidentally create:

```text
Zoom output -> mix -> Zoom input -> Zoom output -> ...
```

The engine should detect obvious graph cycles before applying.

It should also provide optional runtime feedback detection based on rapidly escalating repeated signal, but topology validation is the first line of defense.

The guitar-lesson graph must specifically prevent:

```text
teacher return -> teacher send
```

unless intentionally enabled.

---

## 31. Clipping and headroom

Mixing multiple unity-gain sources can clip.

For example:

```text
guitar 0 dB
+
voice 0 dB
```

can exceed 0 dBFS.

The engine should support:

- per-source gain;
- bus gain;
- peak meters;
- optional transparent limiter / safety limiter.

Do not silently normalize everything.

The graph should expose the chosen policy.

Example:

```yaml
policy:
  clip_protection: true
  limiter_ceiling_dbfs: -1
```

---

## 32. First implementation milestone

The fastest useful vertical slice is:

```text
USB input
   |
   v
audiorouted
   |
   +--> physical output
   |
   +--> one virtual microphone
```

CLI:

```bash
audioroute virtual create "Test Send" --input 2
audioroute scenario apply test.yaml
audioroute status test --json
```

This validates:

- hardware input capture;
- mixer;
- physical output;
- virtual driver;
- daemon/driver transport;
- agent CLI.

No application taps are required yet.

---

## 33. Second milestone

Add Core Audio Process Taps:

```text
Zoom output -> tap -> mixer -> physical output
```

Then the full guitar-lesson scenario is possible.

---

## 34. Third milestone

Make the system resilient:

- bundle-ID process reattachment;
- USB reconnect;
- AirPods reconnect;
- graph persistence;
- atomic graph replacement;
- clock drift;
- resampling;
- diagnostics;
- metering;
- driver active-client reporting.

This is the point at which it becomes dependable enough for nontechnical users through an agent.

---

## 35. Prototype option using BlackHole

If speed of proof-of-concept matters more than architecture, temporarily replace our virtual-device driver with BlackHole:

```text
USB input / app taps
        |
        v
    audiorouted
        |
        v
   BlackHole
        |
        v
 Zoom / OBS / etc.
```

This can validate almost all routing logic before the custom driver exists.

But this should be treated as a prototype layer, because it does not naturally provide the product model of arbitrary dynamically named virtual devices.

BlackHole reference:

https://github.com/ExistentialAudio/BlackHole

BlackHole supports configurable channel counts and is a useful HAL-driver reference. Its GPLv3 licensing must be respected.

---

## 36. Suggested implementation stack

### Daemon / engine

Prefer:

- Swift for Core Audio control-plane integration;
- C / C++ / Swift carefully written for real-time audio;
- Accelerate/vDSP where useful;
- Core Audio AudioConverter or equivalent for sample-rate conversion.

### Driver

Use Apple’s Audio Server plug-in / Driver Extension samples as starting architecture.

### CLI

Swift is a good fit because the daemon and CLI can share types and Codable schemas.

A Rust CLI is also reasonable if desired, but keeping the Core Audio control layer in Swift/C minimizes bridging complexity.

### IPC

Prefer:

- XPC for native macOS integration; or
- a versioned Unix-domain socket protocol.

Protocol must be versioned independently from CLI presentation.

---

## 37. CLI contract for coding agents

The CLI documentation should explicitly promise:

### Structured output

Every inspect/status/apply command supports JSON.

### Idempotency

```bash
audioroute scenario apply x.yaml
audioroute scenario apply x.yaml
```

has the same resulting state.

### No hidden prompts

Commands never wait for stdin unless an interactive flag is passed.

### Explicit user-action objects

If macOS or a third-party application requires a click, return it as structured data.

### Stable error codes

Example:

```text
E_PERMISSION_SYSTEM_AUDIO
E_PERMISSION_MICROPHONE
E_DEVICE_NOT_FOUND
E_DEVICE_AMBIGUOUS
E_APP_NOT_RUNNING
E_APP_CAPTURE_UNAVAILABLE
E_FORMAT_UNSUPPORTED
E_GRAPH_FEEDBACK
E_DRIVER_NOT_INSTALLED
E_VIRTUAL_DEVICE_NOT_CONSUMED
E_CLOCK_SYNC_FAILED
E_OUTPUT_DISCONNECTED
```

### Dry run

```bash
audioroute scenario apply lesson.yaml --dry-run --json
```

should resolve the real machine state but change nothing.

### Verification

```bash
audioroute scenario verify guitar-lesson --json
```

should answer whether the requested outcome is currently true as far as the router can observe.

---

## 38. Ideal coding-agent interaction

The user says:

> “Set up my remote guitar lesson. Use the USB interface for the guitar, the MacBook mic for my voice, Zoom for the call, and my AirPods for listening.”

The coding agent does approximately:

```bash
audioroute devices list --json
audioroute apps list --json
audioroute permissions --json
```

It resolves:

```text
USB interface UID
MacBook microphone UID
AirPods UID
Zoom bundle ID
```

It writes one complete scenario file: `/tmp/guitar-lesson.yaml`.

Then:

```bash
audioroute graph validate /tmp/guitar-lesson.yaml --json
audioroute scenario apply /tmp/guitar-lesson.yaml --json
audioroute scenario verify guitar-lesson --json
```

The result may be:

```json
{
  "state": "ready",
  "working": true,
  "requires_user_action": [
    {
      "application": "zoom.us",
      "action": "select_input_device",
      "device": "Guitar Lesson Send"
    }
  ],
  "warnings": [
    {
      "code": "bluetooth_monitor",
      "message": "AirPods add unavoidable listening latency."
    }
  ]
}
```

The user sees only the result of the scenario, not its internal routing model:

> “The lesson routing is ready. In Zoom, select **Guitar Lesson Send** as your microphone. Your guitar and voice will go to the teacher; your AirPods will play the guitar and the teacher. Your voice is not sent back to your AirPods. AirPods will add some guitar-listening delay because they are Bluetooth.”

That is the intended product experience.

---


## Scenario invariants

These rules should be treated as part of the public contract:

- one named scenario contains all of the routing required for one user workflow;
- a scenario can have many inputs and many outputs;
- each output has an independent per-input mix;
- the same input can have different gain, mute, and channel-map settings on every output;
- each output also has an independent master gain;
- input/source trim is global to that source inside the scenario, but per-output input gain is not;
- changing one output's mix never changes another output's mix;
- a disconnected endpoint becomes silent/discarding without stopping the scenario;
- reconnecting the same stable device resumes automatically;
- virtual and physical destinations are both simply outputs.


## 39. Success criteria for the guitar lesson

The setup is considered working only when all of the following are true:

- USB interface is connected;
- guitar input has signal;
- voice mic is connected and has signal;
- `Guitar Lesson Send` exists as a virtual Core Audio input;
- guitar reaches the send mix;
- voice reaches the send mix;
- Zoom return does **not** reach the send mix;
- Zoom is consuming `Guitar Lesson Send`, or the CLI clearly reports that this selection still needs to be made;
- guitar reaches the AirPods output;
- Zoom return reaches the AirPods output;
- voice mic does not reach the AirPods output unless requested;
- changing guitar level in the teacher output does not change guitar level in the AirPods output;
- no feedback cycle exists;
- no persistent clipping is detected;
- no continuous underruns/overruns are occurring;
- reconnect behavior is armed;
- Bluetooth-latency warning is surfaced.

---

## 40. Non-goals for the first version

Do not turn the first release into a DAW.

Not required initially:

- AU/VST hosting;
- EQ;
- compression;
- recording;
- waveform editing;
- network audio;
- MIDI routing;
- spatial audio;
- elaborate GUI;
- cloud sync;
- account system.

The core value is:

```text
describe routing intent
       ->
agent applies CLI configuration
       ->
audio path works
```

---

## 41. Future GUI

A GUI can come later.

It should simply edit the same scenario model used by the CLI.

That means the system should never have:

```text
GUI configuration model
```

separate from:

```text
CLI configuration model
```

Both should be clients of the daemon’s scenario/graph API.

A future Loopback-style graph editor becomes a visualization of the same declarative graph.

---

## 42. Future MCP / agent integration

The CLI should be sufficient for Codex or Claude Code from day one.

Later, an MCP server can wrap the exact same API:

```text
list_audio_devices
list_audio_apps
create_virtual_device
apply_audio_graph
inspect_audio_graph
get_audio_meters
verify_audio_graph
delete_audio_graph
```

Do not make MCP the underlying implementation.

The hierarchy should be:

```text
Core engine / daemon API
        |
        +--> CLI
        |
        +--> future GUI
        |
        +--> future MCP server
```

This keeps the actual audio system independent of whichever agent protocol is fashionable.

---

## 43. Important technical references

### Apple: Core Audio

Core Audio overview:  
https://developer.apple.com/documentation/CoreAudio

Process taps:  
https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

Virtual Audio Server Driver plug-in:  
https://developer.apple.com/documentation/CoreAudio/creating-an-audio-server-driver-plug-in

Audio Server plug-in + Driver Extension:  
https://developer.apple.com/documentation/CoreAudio/building-an-audio-server-plug-in-and-driver-extension

Aggregate devices:  
https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice

### Loopback behavior to emulate

Sources:  
https://www.rogueamoeba.com/support/manuals/loopback/?page=sources

Output channels:  
https://www.rogueamoeba.com/support/manuals/loopback/?page=outputchannels

Monitors:  
https://www.rogueamoeba.com/support/manuals/loopback/?page=monitors

Pass-Thru:  
https://www.rogueamoeba.com/support/manuals/loopback/?page=passthru

### Open-source references

BlackHole — virtual Core Audio loopback driver:  
https://github.com/ExistentialAudio/BlackHole

catap — Python/Core Audio process-tap bindings and recorder:  
https://github.com/sbetko/catap

AudioTee — Swift Core Audio tap CLI:  
https://github.com/makeusabrew/audiotee

Fader — per-app capture, mute, mix, and re-render using process taps:  
https://github.com/hatimhtm/Fader

---

## 44. Recommended product principle

The project should optimize for this statement:

> **The user describes who should hear what. The agent handles audio engineering.**

The CLI exists to make that reliable.

The user should not have to learn:

- Core Audio;
- aggregate devices;
- sample rates;
- process taps;
- channel maps;
- virtual drivers;
- clock drift;
- buffer sizes;
- Audio MIDI Setup.

The coding agent can understand those details because the CLI exposes them in a stable, documented, machine-readable way.

The final test is not whether a graph was created.

The final test is whether the intended people and applications hear exactly the intended audio, with the lowest practical latency, and nothing else.
