# A channel changed or went silent during a call

Three selections can differ: AudioRoute's explicit source channels, the interface's own internal routing, and the call application's microphone/channel settings. A channel number in Zoom or another app does not establish that AudioRoute changed its channel.

## Capture before and after snapshots

Run these commands before enabling computer-audio sharing, then repeat them afterward with different filenames:

```sh
audioroute scenario show guitar-lesson --json > route-before.json
audioroute status guitar-lesson --json > status-before.json
audioroute devices list --json > devices-before.json
```

In `status`, each endpoint's `channel_indices` contains its one-based selected channels. The older `channels` field is the number of selected channels, so `channels: 1` alone does not mean channel 1. Compare `resolved_device`, `sample_rate`, `callbacks_advancing`, `signal`, and `recent_reconnects` as well. Strum while taking a snapshot: silence while idle is normal, and meters reflect the latest block rather than the entire interval.

Use `devices inspect ID --json` with the stable device ID from discovery. Its `input_streams` and `output_streams` report stream order, starting channels, channel counts, and formats. Preferred stereo channels are the device's defaults, not AudioRoute's explicitly selected channels. Unsupported properties appear as empty arrays. AudioRoute reconnects when a referenced device's stream layout changes, preserving the scenario's channel selection.

A silent channel with advancing callbacks means the device is delivering buffers but the selected source has no qualifying signal. It does not prove that the signal moved to another channel. These diagnostics do not measure unselected channels or expose the MOTU's internal routing matrix.

## Restore the intended selection

For the explicit guitar-lesson route, Zoom's microphone should be **Guitar Lesson Send**, and its speaker should be **Guitar Lesson Return**. If Zoom selects the physical interface directly, it bypasses the Send mix and uses Zoom's own multichannel selection. AudioRoute cannot read or change that private Zoom setting through its CLI. Reselect the virtual microphone in Zoom, and check it again after starting a screen share with computer audio.

If AudioRoute's saved channel is incorrect, export its latest configuration so current levels are preserved:

```sh
audioroute scenario export guitar-lesson --json > lesson-export.json
python3 - <<'PY'
import json
from pathlib import Path
spec = json.loads(Path('lesson-export.json').read_text())['result']
spec['inputs']['guitar']['channels'] = [1]  # The confirmed physical guitar channel.
Path('lesson-fixed.json').write_text(json.dumps(spec, indent=2) + '\n')
PY
audioroute scenario apply lesson-fixed.json --dry-run --json
audioroute scenario apply lesson-fixed.json --json
audioroute meter guitar-lesson --json
audioroute scenario verify guitar-lesson --json
```

Review dry-run resolution before applying. Applying an unchanged scenario is idempotent; it is not a forced restart. If the interface itself has rerouted its USB channels, restore that mapping in the interface's controls, or explicitly select a newly confirmed channel in the scenario. Do not automatically switch to whichever channel happens to be loudest.

If all routing is correct but capture remains stuck, `audioroute daemon stop` followed by `audioroute daemon start` recreates the audio graph and restores saved scenarios. This briefly interrupts **all** AudioRoute routes; use it between calls after checking `daemon status` and `doctor guitar-lesson`.
