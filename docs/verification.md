# Verification record — 2026-10-04

The development implementation builds and passes automated tests. Administrator-authorized installation and Core Audio restart completed. Live HAL microphone/duplex tests, full daemon routing, and application capture all passed. The user confirmed guitar monitoring through AirPods and both voice and guitar in Zoom's microphone playback test, including the adjusted balance. An actual remote lesson remains unverified.

## Passed

- Release Swift CLI and daemon build, with ad hoc signed `AudioRoute.app`.
- Universal arm64/x86_64 HAL driver and system-domain XPC transport broker build and signature verification.
- 24 Swift tests: 13 scenario/parser/offline-mixer tests, 7 native engine tests, 4 control/persistence tests.
- Isolated CLI/daemon integration: discovery, validation, dry run, idempotent apply, independent levels, invalid-update rollback, deletion protection, restart persistence, concurrent daemon protection, and truthful degraded verification.
- HAL host harness under AddressSanitizer and UndefinedBehaviorSanitizer: dynamic registry churn, bounded property reads, immutable shared-memory channel bounds, two input clients, duplex samples, XPC shared-memory mapping, timestamps and client counts.
- Real-time harness under AddressSanitizer and UndefinedBehaviorSanitizer: 2,822,399 source frames over simulated 64 seconds, 44.1-to-48 kHz conversion, positive/negative 1000 ppm drift, 16-frame jitter, independent destination matrices, zero xruns, no render-loop allocation/free, and buffer boundaries.
- Real device discovery outside the execution sandbox found nine Core Audio endpoints, including the 24-channel USB Audio Out interface, built-in microphone/speakers, USB speakers, display audio, and existing virtual devices.

- Installed driver loaded by macOS, with the system-domain broker running as `_coreaudiod` and shared audio accessible from the HAL sandbox.
- Live input-only endpoint: two Core Audio clients received 158,304 and 156,000 expected nonzero samples; no incorrect samples; 508 driver callbacks.
- Live duplex endpoint: two input clients received 160,320 and 159,360 expected samples, and the output direction returned 193,920 expected samples; no incorrect samples; 1,012 driver callbacks.
- Both devices reported zero active clients after stopping. Temporary endpoints were removed, and daemon diagnostics reported healthy.

- Live daemon routing: virtual output → source capture → two independent mixes → two virtual microphones. The CLI reported `working: true` and `xruns: 0` while clients were active. Three gain stages delivered 1,152,640 correct samples with zero incorrect samples, proving positive output gain and independent per-output input gain. Short silent transitions occurred during graph replacement. The serial rerun cleaned up successfully.

- Live application capture: the dedicated test app → Core Audio process tap → daemon mixer → virtual microphone delivered **288,128 matching PCM samples and zero unexpected samples across 752 callbacks**. TCC logs confirmed System Audio Recording permission granted to `org.audioroute.daemon`. The temporary scenario and both endpoints were deleted successfully.

Earlier application-tap attempts waited in Core Audio while capture authorization was unresolved and the Mac was locked. The daemon was corrected to use a Cocoa main event loop and LaunchServices startup, giving AudioRoute its own permission identity. After the Mac was unlocked and authorization granted, the same isolated test passed. Synchronous Core Audio startup can still delay control requests while authorization is pending.

All 24 Swift tests, driver sanitizer tests, realtime stress tests, and isolated CLI tests passed again after the startup changes. The blocked test daemon was recovered, helper stopped, test endpoints removed, and the final daemon reported healthy with no scenarios and no restore errors.

## Not yet verified

- Application restart/reconnect behavior under real signal.
- The full guitar-lesson scenario with a remote participant.

The driver and broker are installed under `/Library`. Core Audio was restarted using administrator `killall coreaudiod` after SIP blocked `launchctl kickstart`; SIP remains enabled.

## Guitar lesson hardware test in progress

The user authorized MOTU UltraLite-mk4 input 1 for guitar, the AirPods microphone for voice, and AirPods playback. `scenarios/guitar-lesson.yaml` is active and the input-only `Guitar Lesson Send` endpoint is visible in macOS Sound settings. The user confirmed the MOTU hardware input meter moves. Physical capture and mixer meters advance; observed guitar peaks reached approximately -29 dBFS and the listening mix approximately -38 dBFS. **The user reports hearing no routed audio**, so these meters do not establish audible playback. Sound settings show the AirPods selected, unmuted, at 38% volume. The virtual microphone has not yet been observed being consumed by Zoom; the complete lesson remains unverified.

The live 512-frame/44.1 kHz guitar producer exposed repeated underruns in the 256-frame/48 kHz virtual send. A regression reproduced 147 send underruns and 12 listening underruns. Buffer reserve sizing now accounts for producer batches. Seven 180-second simulations under ASan/UBSan, with 512/480-frame producer batches, independent 256/512-frame sinks, ±1000 ppm drift, and 3 ms source jitter, passed with zero underruns, overruns, or bad samples. Seven engine tests also passed. New physical-delivery counters distinguish rendering from complete device buffer writes; a separate buffer test covers planar audio and disabled NULL buffers.

Signal detection now uses a documented -60 dBFS threshold rather than treating approximately -80 dBFS input noise as signal. This remains a heuristic, not proof of audibility. Physical output verification also requires recent complete device-buffer writes. Neither proves downstream headset audibility.

After the corrected release restarted, a 10.6-second live observation delivered 513,024 complete frames and 1,026,048 nonzero samples into the AirPods output buffers, with zero unavailable buffers, underruns, or overruns. The user still reported silence. Guitar monitoring gain was increased from -3 to +9 dB while retaining the -6 dB listening master; a subsequent observation again showed complete writes and zero xruns. Audible confirmation is still pending; the buffer fix alone did not resolve the reported silence.

The user then confirmed ordinary audio was also silent in the AirPods. Guitar monitoring was restored to -3 dB, and the daemon was stopped (process exit confirmed) for an ordinary-playback comparison. AirPods remain connected, selected, and unmuted in macOS settings. Whether playback recovers with AudioRoute stopped is awaiting user confirmation.

The user subsequently confirmed YouTube playback with AudioRoute stopped, and then **both YouTube and guitar audible after restarting the complete lesson route**. The full configuration still uses the AirPods microphone. Post-restart status showed zero xruns and complete output writes. The exact cause of the earlier silence remains undetermined; human confirmation now establishes guitar monitoring.

Zoom Audio settings visibly showed `Guitar Lesson Send` selected as microphone, Original sound for musicians selected, and high-fidelity music mode enabled. Its speaker was changed from SoundPipe to the requested AirPods. The user was asked to run Zoom's microphone recording/playback test with voice and guitar; that result remains pending.

The user confirmed hearing both voice and guitar in the Zoom microphone playback test, with voice much louder. The Zoom send's voice gain was reduced from 0 to -9 dB and saved in the active scenario and `scenarios/guitar-lesson.yaml`. Listening gains are unchanged. Final subjective balance and an actual remote lesson remain to be checked.

The user subsequently confirmed the adjusted balance looks good. Local lesson testing is complete: guitar monitoring, Zoom input selection, voice-plus-guitar playback, and subjective balance were confirmed. The saved lesson route is left running. A remote participant test remains outside this local verification.

## Explicit virtual return (subsequent user-requested change)

The lesson now uses an output-only stereo `Guitar Lesson Return` device (ID `guitar-lesson-return`) instead of capturing Zoom with a process tap. Zoom's Audio settings visibly confirm Return as speaker and Send as microphone. The teacher source is `virtual_output`; `application` and `mute_original` were removed. The existing guitar and voice gains remain unchanged. Return is mixed only into AirPods listening and remains muted in the teacher-send mix, preventing internal echo. After publication/reconnection, status confirms Return connected with advancing frames, complete AirPods writes, and zero xruns. Audible verification of this revised return path is pending the Zoom speaker test.

The user confirmed the Zoom speaker test was audible through the explicit return path. The saved lesson remains on the virtual Send/Return configuration.

## Self-describing CLI

Added offline command-specific help, a JSON command catalog, configuration JSON Schema, complete routing guide, and two exportable YAML examples. The release CLI build passed 115 offline discovery checks with no daemon launch, socket creation, or state changes. Both examples passed the current ScenarioSpec parser and draft 2020-12 schema validation; the schema itself passed its meta-schema check. Existing isolated CLI integration also passed (discovery, dry-run, apply, idempotency, independent levels, degraded verification, rollback, deletion guard, restart persistence). Only `build/audioroute` was replaced; the running lesson daemon was not restarted.

## Distribution and onboarding preparation

Universal arm64/x86_64 CLI, daemon, HAL and broker artifacts were built in isolated release directories. Actual Mach-O metadata in both slices confirms compatibility with macOS 14.2. `setup` read-only diagnostics and JSON flag placement passed tests without creating a daemon socket or state; default output on this Mac reports installed components ready and the background app running. Offline help checks and isolated CLI integration passed with the new executable. The running application was not replaced or restarted.

An unsigned development installer was assembled at `build/installer-verified/AudioRoute-0.1.0-universal-unsigned.pkg`. Non-installing package expansion verified fixed installation paths, root ownership, universal slices, deployment targets, code signatures, bundle/CLI/package version agreement and installer script syntax. The installer preserves existing user state and does not restart audio. Local pkgbuild emitted nonfatal `write: Permission denied` messages while packing metadata; expanded executable/bundle signatures and payload checks passed. This does not substitute for a clean-machine installation or a clean signed CI run.

GitHub workflow YAML parses and pinned action tags were checked against their official repositories. It prepares a signed/notarized/stapled package and draft release only after tests. No workflow or signed/notarized installation was run: repository identity and signing credentials are still outstanding. Fresh-machine installation/upgrade, real Intel audio and public distribution remain unverified.

## Reproduce

```sh
scripts/test.sh
scripts/build.sh
python3 scripts/test-cli.py "$(swift build -c release --show-bin-path --disable-sandbox)"
```

After administrator-authorized installation and activation, run `scripts/test-live-driver.sh build/audioroute`. It uses temporary virtual-only endpoints and cleans up their registry entries. No physical audio is emitted.

See README and `docs/cli.md` for current implementation boundaries. Internal buses are available in the offline model but rejected by the live engine; clip protection uses a hard ceiling; development signatures are not notarized distribution signatures.
