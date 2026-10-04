# Agent quickstart: turn an audio goal into a working Mac route

Use this guide when the user asks you to create an AudioRoute scenario. Work from the user's requested sources, destinations and exclusions. The CLI runs on the Mac whose audio you are routing; a remote agent without access to that Mac cannot configure its devices.

## 1. Locate AudioRoute and learn its interface

Use `command -v audioroute`; in a source checkout, look for `build/audioroute`. Use that executable consistently. Run:

```sh
audioroute --help --json
audioroute guide --json
audioroute schema --json
audioroute examples --json
audioroute setup --json
```

These discovery commands and default setup do not start audio. Do not assume an installation is healthy merely because a binary exists. If missing, explain that no signed release is currently published; the developer path is in [development.md](development.md). Do not substitute an unsigned package for a signed public release or bypass Gatekeeper. The user handles required administrator and privacy approvals.

## 2. Discover the actual devices

After installation is ready, use `audioroute setup --start --json` to start the background app. Starting it restores existing scenarios, so inspect `scenario list` and preserve unrelated routes. Read `devices list --json` and `permissions --json`. Resolve physical devices by their returned stable IDs; never copy a different person's hardware IDs from an example.

Ask for missing physical facts such as the instrument's input channel and the intended microphone/headphones. If several devices could match, ask which one. Do not change the Mac's default devices as a shortcut.

## 3. Prefer explicit virtual Send and Return for a call

For the guitar lesson, create these endpoints after checking `virtual list` for existing devices:

```sh
audioroute virtual create "Guitar Lesson Send" --input 2 --output 0 --json
audioroute virtual create "Guitar Lesson Return" --input 0 --output 2 --json
audioroute examples explicit-virtual-guitar-lesson --json
```

Input channels make a virtual **microphone**: AudioRoute writes, Zoom reads. Output channels make a virtual **speaker**: Zoom writes, AudioRoute reads. The normalized IDs for the commands above are `guitar-lesson-send` and `guitar-lesson-return`. Confirm returned IDs and publication rather than assuming immediate availability.

Extract the example's `result.content` as YAML. Replace its placeholder physical IDs and channel selections with discovery results, and change the example's `lesson-send`/`lesson-return` references to the endpoints above. Choose an appropriate scenario ID. Keep the intended routing explicit:

| Source | Send to teacher | Listen locally |
| --- | --- | --- |
| Guitar | Yes | Yes |
| Voice | Yes | No |
| Teacher / virtual Return | No | Yes |

Set independent conservative gains. A `virtual_output` **input** reads Return; a `virtual_input` **output** writes Send. No application process tap is required for this pattern. Use application capture only when it meets the user's intent better, explaining that difference.

## 4. Validate, apply, and select the app devices

Save the configuration to a local file. Run `scenario validate FILE --json`, then `scenario apply FILE --dry-run --json`. Resolve actual errors and inspect degraded-resource warnings before applying. Apply the reviewed file with `scenario apply FILE --json`.

In Zoom, select **Guitar Lesson Send** as microphone and **Guitar Lesson Return** as speaker. The CLI cannot select those settings itself. Use an authorized UI tool if available, otherwise give the user those exact selections. Actual playback goes from AudioRoute's listening mix to their selected headphones.

## 5. Test with the user, then save the final balance

Inspect `status ID`, `meter ID`, and `scenario verify ID` while real signal is present. Metering is a snapshot; idle sources can make verification incomplete. Generic virtual input consumption does not prove that Zoom is the reader.

Have the user confirm guitar monitoring, absence of their own live microphone in their headphones, and Zoom's speaker and microphone playback tests. During Zoom's recorded microphone test, hearing their recorded voice is expected. A live remote call is a separate check. Do not equate successful apply, callbacks, or meters with audible success.

Adjust voice/guitar only in the requested destination using `level set`; use `help level set` for exact syntax. Level changes persist in the daemon's saved state but do not update the original YAML. To save a reusable configuration reflecting the final balance, run `scenario export ID --json` and write only its `result` object to a JSON file. Reapplying an old YAML file restores its old levels.

Finish with the chosen app devices, what was tested, the saved scenario/file, and any remaining user action. Keep personal hardware configurations local rather than committing them to the project.

For channels that change or go silent during a call, see [channel troubleshooting](channel-troubleshooting.md). Capture before/after route, status, and device snapshots before changing the routing.
