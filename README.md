# AudioRoute

AudioRoute is a macOS CLI and background daemon for routing selected physical inputs and application audio into independent destination mixes. Each named scenario owns its inputs, the mix for every output, and each output's master gain. Positive gain is supported.

The project includes a custom Core Audio HAL plug-in, shared-memory audio transport, a system transport broker, Swift control plane, and a preallocated C audio engine. The broker supplies shared-memory handles across the HAL sandbox boundary. The implementation is local: it does not require BlackHole, a cloud service, or a GUI.

Automated tests and local guitar/voice routing through AirPods and Zoom playback have passed. A remote call and fresh-machine installer testing remain outstanding; see the [verification record](docs/verification.md).

## Install on a Mac

Requires macOS 14.2 or later. The universal installer supports Apple Silicon and Intel; users do not need Xcode, Homebrew, Python, or a source checkout.

The repository is currently private: [tzvister/tzvi-audio-router](https://github.com/tzvister/tzvi-audio-router). A signed release is not published yet. Once a release is available:

1. Download **AudioRoute-VERSION-universal.pkg** from the [Releases page](https://github.com/tzvister/tzvi-audio-router/releases).
2. Open it and follow the macOS installer. Approve the administrator prompt while signed into the account that will use AudioRoute.
3. Restart the Mac to load the audio driver, then open Terminal and run:

```sh
audioroute setup
audioroute setup --start
```

The installer includes the CLI, AudioRoute app, virtual audio driver, and transport service. It does not interrupt active audio or start microphone capture. `setup` checks installation; `setup --start` starts the background app and restores saved routes. macOS asks for microphone access when an intended route first needs it. Application capture has a separate permission; explicit virtual speaker routing avoids that requirement.

For a lesson, use **Send** as the meeting app's microphone and **Return** as its speaker. AudioRoute mixes Return with your guitar for your headphones. Run `audioroute examples` for templates and `audioroute guide` for the complete setup workflow. `audioroute --help --json` gives agents the command catalog. If your shell cannot find the command, use `/usr/local/bin/audioroute setup`.

This release supports one routing account per Mac. Development packages ending in `-unsigned.pkg` are local test artifacts, not public releases. Maintainers: see [release packaging](docs/releasing.md).

## Build and test

Requires macOS 14.2 or later and an Xcode installation with command-line tools selected. Process taps require macOS 14.2. Run from the repository:

```sh
scripts/test.sh
python3 scripts/test-cli.py
scripts/build.sh
```

The build produces `build/audioroute`, `build/AudioRoute.app`, and `build/AudioRoute.driver`. Development builds use ad hoc signatures unless a signing identity is configured. This is a development installation, not a notarized distribution package.

## Use

The daemon lives in the app bundle to give microphone and system-audio permission a stable owner. The CLI communicates with it over a private Unix socket.

Learn directly from the executable with `build/audioroute --help`, `guide`, `schema`, and `examples`. `help COMMAND SUBCOMMAND` (or `COMMAND SUBCOMMAND --help`) explains individual commands. Add `--json` to obtain machine-readable help. These discovery commands work without the daemon and do not change audio.

```sh
build/audioroute daemon start --json
build/audioroute devices list --json
build/audioroute apps playing --json
build/audioroute permissions --json
```

To publish virtual devices, install the built driver and its system transport broker once from an administrator shell, then restart the Mac to load them:

```sh
sudo scripts/install-driver.sh
```

Use discovery results to replace the placeholder device UIDs in `examples/guitar-lesson.yaml`. Create its virtual microphone and apply the complete scenario:

```sh
build/audioroute virtual create "Guitar Lesson Send" --input 2 --output 0 --json
build/audioroute scenario validate examples/guitar-lesson.yaml --json
build/audioroute scenario apply examples/guitar-lesson.yaml --dry-run --json
build/audioroute scenario apply examples/guitar-lesson.yaml --json
build/audioroute scenario verify guitar-lesson --json
```

Select **Guitar Lesson Send** as Zoom's microphone. While playing the guitar and speaking, inspect status and meters. A successful apply confirms the configuration was accepted; measured callbacks, signal, buffer health, and virtual input consumption establish whether the audio path works. Missing endpoints produce a degraded scenario and reconnect automatically when enabled.

```sh
build/audioroute status guitar-lesson --json
build/audioroute meter guitar-lesson --json
build/audioroute level set scenario:guitar-lesson output:teacher-send input:guitar --db -6 --json
build/audioroute level set scenario:guitar-lesson output:airpods input:guitar --db 3 --json
build/audioroute level set scenario:guitar-lesson output:airpods --master-db 2 --json
```

Those two guitar levels are independent. A source-wide adjustment uses `input:guitar --db ...` without an output.

## Current boundaries

- Physical I/O supports floating-point Core Audio device formats. Unsupported formats fail explicitly.
- Application capture selects Core Audio processes belonging to a bundle identifier. Browser audio is isolated at application level; individual tabs are not identified.
- The virtual driver reports activity and delivered frames. It does not identify the application reading a virtual microphone or reliably distinguish every client direction.
- Virtual channel layout and sample rate are immutable for a given ID. The HAL host retains deleted device slots for callback safety, with a limit of 128 distinct IDs over that host process's lifetime; restarting the Mac resets those slots.
- Clip protection is a hard sample ceiling, not a transparent look-ahead limiter. Disable it only when the downstream destination can safely handle the resulting level.
- Independent hardware clocks use buffered interpolation and drift correction. Bluetooth listening latency remains observable and cannot be removed by routing software.
- Internal buses are supported by configuration validation and the offline reference renderer; runtime support must be checked before using them.
- The CLI never changes the Mac's default input/output device, selects Zoom's microphone, or generates a test tone automatically.

See [CLI and configuration](docs/cli.md), [testing and live verification](docs/testing.md), and the [product brief](docs/product-brief.md).
