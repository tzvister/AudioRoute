# Testing and live verification

Automated tests cover the control plane and sample-level audio behavior. Passing them does not by itself establish that a newly installed HAL plug-in loads in `coreaudiod`, that macOS permissions were granted, or that another application chose the virtual microphone.

## Automated checks

```sh
scripts/test.sh
python3 scripts/test-cli.py
scripts/build.sh
```

`scripts/test.sh` sets local compiler cache paths and runs Swift tests plus the driver harness. The driver test compiles with AddressSanitizer and UndefinedBehaviorSanitizer and exercises HAL behavior in a host harness. It does not install or reload the system driver. The CLI test launches a separate daemon in a temporary state directory and checks discovery, dry-run isolation, idempotency, independent levels, truthful degraded status, rollback, deletion guards, and restart persistence. It uses absent device UIDs and emits no audio. If your toolchain uses a different binary directory, pass it as `python3 scripts/test-cli.py /absolute/build/bin`.

The core tests check YAML/JSON round trips, typo rejection, invalid channel maps, one-based channels, destination-specific gain isolation, source trim, mute, above-unity gain, clipping counts, missing-source silence, matrices/downmixing, bus rendering, and feedback rejection. The offline renderer operates on planar 32-bit float PCM and is intentionally separate from the real-time callback path.

## Live physical route

1. Start the bundled daemon and inspect `devices list` and `permissions`.
2. Create a scenario using an actual capture device UID and an actual playback device UID. Use the minimal configuration in `cli.md`.
3. Validate, dry-run, and apply it. Grant the specific microphone permission if macOS requests it.
4. Play or speak into the selected input and inspect `status ID`, `meter ID`, and `scenario verify ID`.
5. Check that source and destination callbacks advance, levels follow the source, and underrun/overrun counts do not continue rising.
6. Change the output's gain and confirm the destination changes by the intended amount. Compare against a second output if available to confirm their levels remain independent.
7. Disconnect the source or output. The scenario should stay alive and become degraded. Reconnect the same UID and confirm callbacks/signal recover when `reconnect: true`.

No test tone is generated automatically. Use actual signal from the selected source.

## Live virtual microphone

1. Install the driver and transport broker with `sudo scripts/install-driver.sh`, then restart the Mac. Installation and reboot are required to test actual HAL publication; a host-side driver harness does not establish broker access inside `coreaudiod`.
2. Run `virtual create "Test Send" --input 2 --output 0`. Inspect `test-send` and confirm `published` is true.
3. Add an output with `type: virtual_input`, `virtual_device: test-send`, `channels: 2`, and an explicit input mix.
4. Apply the scenario. In a consuming application, choose **Test Send** as its microphone.
5. Confirm the application's input meter responds and the router's driver callback/delivery counters advance. Check the consumer's audio rather than treating a device name in a selector as sufficient proof.
6. Stop and restart the daemon and confirm persisted configuration is restored. Reapply the same file and confirm `changed: false` without duplicate endpoints.

The HAL plug-in reports total active clients and frame-delivery counters. A client count alone cannot establish which application is reading the device. End-to-end verification should combine router counters with the intended application's observed input.

A silent HAL integration harness can open the published virtual microphone and verify that input callbacks and driver frame-delivery counters advance without emitting sound. That establishes publication and driver/transport I/O, while source signal and the intended application's selection still require separate observation.

## Live guitar lesson

The configured local lesson is `scenarios/guitar-lesson.yaml`. It uses explicit virtual devices: select **Guitar Lesson Send** as Zoom's microphone and **Guitar Lesson Return** as Zoom's speaker. AudioRoute combines Return with MOTU input 1 for AirPods playback, and combines guitar with the AirPods microphone for Send. The voice contribution to Send is -9 dB. No application tap is used in this local lesson. To recreate the Return endpoint, run `build/audioroute virtual create 'Guitar Lesson Return' --input 0 --output 2`. Apply the scenario, then use Zoom's speaker and microphone tests before a remote call.

The alternative application-capture example below remains available for apps without output selection.

Use `examples/guitar-lesson.yaml` with real UIDs and the registered virtual device ID. Declare Zoom as `consumer_application` on the send output. After selecting the virtual microphone in Zoom, check these paths independently:

| Source | Teacher send | Listening output |
| --- | --- | --- |
| Guitar | Audible at send gain | Audible at listening gain |
| Voice | Audible | Muted |
| Zoom return | Muted | Audible |

Start the call and let the other participant speak to test the process tap. Verify microphone and guitar with real signal. Quit/relaunch Zoom to exercise bundle-ID reattachment. Test AirPods reconnection and surface their listening latency. Lower mix gain if clipping rises; positive master gain remains available, but it consumes headroom.

Application taps isolate a bundle's Core Audio processes. Google Meet inside Chrome cannot be distinguished from unrelated Chrome tab audio by the configuration model. Choose an application whose captured audio matches the desired scope.

## Result reporting

Record the commands run, exact hardware/application identities, observed callbacks and signal, permission state, clipping/xrun changes, and any user action still required. Distinguish these outcomes:

- The scenario parses and validates.
- The runtime graph starts, possibly degraded while endpoints are absent.
- Audio samples pass automated mixing/transport tests.
- Physical routing is measured on this Mac.
- A virtual device is published by the installed HAL driver.
- The intended application consumes the virtual microphone and the requested people hear the intended mix.

Only claim the last outcome after observing it. A build, configuration apply, or host-side driver test is not equivalent to a live call.

## Installed virtual-only end-to-end checks

`scripts/test-live-router.sh build/audioroute` measures independent output gain through the real daemon and asserts CLI verification while signal is flowing. `scripts/test-live-tap.sh build/audioroute` tests only its own dedicated helper application; it requires an unlocked Mac and AudioRoute recording authorization. Run live tests serially. The process-tap test passed on this Mac after AudioRoute received recording permission; see `verification.md`.
