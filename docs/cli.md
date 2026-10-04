# CLI and configuration contract

## Built-in discovery

No external documentation or running daemon is needed for:

```sh
audioroute --help                      # command index and discovery entry points
audioroute --help --json               # structured command catalog
audioroute help virtual create         # detailed syntax, arguments, and examples
audioroute level set --help            # equivalent per-command help
audioroute guide                       # complete routing and operation workflow
audioroute schema                      # JSON Schema in result, plus semantic notes
audioroute examples                    # available YAML templates and prerequisites
audioroute examples explicit-virtual-guitar-lesson > lesson.yaml
```

`guide`, `help`, and `examples` accept `--json` for structured output. A named example prints raw YAML by default; its JSON form contains `result.content` and prerequisite notes. The schema describes configuration structure; device resolution, matrix dimensions, graph references, and runtime support still require `scenario validate` and apply preflight. All discovery commands run locally without starting the service or changing audio. Unknown help topics fail with `E_USAGE` and exit code 2.

All operational commands produce JSON. `--json` makes agent intent explicit and is accepted throughout the CLI. Responses use protocol version 1:

```json
{"protocol_version":1,"ok":true,"result":{}}
```

Failures have `ok: false` and an `error` object containing stable `code` and actionable `message` strings. Daemon launch/status commands may return their result directly. `--help` and `--version` produce text.

## Commands

| Purpose | Commands |
| --- | --- |
| Background service | `daemon start`, `daemon status`, `daemon stop` |
| Discovery | `devices list`, `devices inspect ID`, `apps list`, `apps playing`, `permissions`, `inspect` |
| Virtual endpoints | `virtual list`, `virtual create NAME --input N --output N`, `virtual inspect ID`, `virtual delete ID --yes` |
| Scenarios | `scenario list`, `scenario show ID`, `scenario export ID`, `scenario validate FILE`, `scenario apply FILE`, `scenario verify ID`, `scenario delete ID --yes` |
| Observation | `status [ID]`, `meter [ID]`, `doctor [ID]` |
| Input trim | `level set scenario:ID input:INPUT --db DB` |
| Destination mix level | `level set scenario:ID output:OUTPUT input:INPUT --db DB` |
| Destination master | `level set scenario:ID output:OUTPUT --master-db DB` |

Mutations support `--dry-run`. Deletion requires `--yes`. Applying an identical persisted scenario is idempotent. A replacement is built before the previous graph is stopped, and a failed apply preserves the previous scenario. Scenarios persist across daemon restarts.

| Exit code | Meaning |
| --- | --- |
| 0 | Command succeeded |
| 1 | Operation failed |
| 2 | Invalid command arguments |
| 3 | Daemon unavailable |
| 4 | Scenario verification incomplete |

`AUDIOROUTE_STATE_DIR` selects the daemon's configuration directory. `AUDIOROUTE_SOCKET` selects its Unix socket; the containing directory must be private and owned by the current user. Set the same variables for the daemon and every CLI process. Virtual device registry/transport use the shared driver directory installed at `/Library/Application Support/AudioRoute`, separate from scenario persistence.

## Minimal scenario

Replace both UIDs with discovery results. Channel numbers are one-based physical channel indices.

```yaml
version: 1
scenario:
  id: physical-route
  name: Physical Route
  target_sample_rate: 48000
  latency_mode: low
inputs:
  instrument:
    type: device_input
    device: coreaudio:device:INPUT_UID
    channels: [1]
    trim_db: 0
outputs:
  headphones:
    type: device_output
    device: coreaudio:device:OUTPUT_UID
    channels: [1, 2]
    master_gain_db: 0
    mix:
      instrument:
        gain_db: -6
        map: mono_to_stereo
policy:
  reconnect: true
  disconnected_input: silence
  disconnected_output: discard
  clip_protection: true
  limiter_ceiling_dbfs: -1
```

JSON uses exactly the same snake_case field names. Configuration files are limited to 1 MiB and unknown fields fail validation to catch mistakes such as `gain_bd`.

## Fields and routing

`scenario.id` is 1–128 letters, digits, underscores, or hyphens, starting with a letter or digit. Input and output keys follow the same rule. Defaults are 48000 Hz and `latency_mode: low`. The validator accepts `low`, `balanced`, and `safe`; the current engine does not promise different device buffer sizes for each label.

Input types:

- `device_input`: a physical capture device identified by `device` and selected `channels`.
- `application_output`: a stable `application: app:<bundle-id>` plus selected channels. `mute_original: true` mutes the application's original playback while the tap owns it.
- `virtual_output`: audio written by another application to the output side of a registered virtual device.
- `bus`: an offline/internal source referencing another output with `source: OUTPUT_KEY`. Runtime availability is separate from configuration validity.

Inputs default to channels `[1, 2]`, `trim_db: 0`, and `mute: false`. Devices and applications are resolved by stable identity; names can be used only where discovery resolution supports them, and ambiguous matches fail.

Output types:

- `device_output`: selected channels on a physical playback device.
- `virtual_input`: the router writes audio that consuming applications read as a microphone. Use `virtual_device: ID` to reference a previously created virtual endpoint. With neither `virtual_device` nor `device`, apply creates the endpoint from `name` (or the output key) and the declared channel count. Its normalized registry ID remains the stable transport identity.
- `virtual_output`: a virtual destination accepted by the schema; delivery currently uses the virtual input side of a registered endpoint, so prefer `virtual_input` for application microphone feeds.
- `bus`: an internal mix in the offline renderer. The live engine may reject it as unsupported.

Outputs require a `mix` mapping. Omitted inputs contribute nothing. Each route defaults to `gain_db: 0` and `mute: false`; each output defaults to `master_gain_db: 0` and `mute: false`. Positive dB is legal up to +60 dB, with a lower bound of -120 dB. Mute is a separate boolean.

`channels: 2` declares a two-channel logical/virtual endpoint; `channels: [1, 2]` selects physical channels explicitly. Channel selections must be unique integers from 1 through 64. The virtual driver currently supports up to 32 channels in either direction and publishes at 48000 Hz; runtime validation enforces its actual layout.

A virtual ID's channel layout and clock are immutable for the lifetime of the HAL host process. Use a new ID when changing the layout. Deleted slots remain allocated to protect existing audio callbacks, and the host supports 128 distinct IDs over its lifetime. Restarting the Mac resets the lifetime allocation count.

Named maps are `identity`/`direct`, `mono_to_stereo`, `stereo`, and `stereo_to_mono`. Without `map`, one source channel into two destination channels duplicates mono; otherwise channel counts must match. An explicit matrix uses destination rows and source columns:

```yaml
map: [[0, 1], [1, 0]] # swap stereo channels
```

The final route gain is input trim + destination-specific input gain + output master gain, expressed in dB. `stereo_to_mono` averages the two channels. A matrix applies its weights in addition to route gain.

## Feedback and verification

Bus cycles and matching virtual endpoint loops are rejected with `E_GRAPH_FEEDBACK`. For a virtual microphone feeding an application, declare `consumer_application: app:<bundle-id>` so validation can detect routing the application's captured return back into its own microphone. Muting that return in the send mix breaks the cycle. `policy.allow_feedback: true` bypasses topology rejection deliberately; it does not make an acoustic feedback loop safe, and the offline renderer cannot solve cyclic buses.

The topology validator sees declared endpoints, not the internals of third-party applications or acoustic paths. Keep the call return muted in the call send even when consumer identity cannot be observed.

`scenario verify` reports measured runtime state and returns exit code 4 when verification is incomplete. Observe signal during actual source activity: silence while nobody speaks does not demonstrate a broken route. The router cannot force Zoom or a browser to choose its virtual microphone; the user selects it in that application's audio settings.
