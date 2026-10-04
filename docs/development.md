# Build AudioRoute from source

This is the developer-preview path. Ordinary users are intended to install a signed package once one is released; see the [README](../README.md).

Requires macOS 14.2 or later and Xcode with its command-line tools selected.

```sh
git clone https://github.com/tzvister/tzvi-audio-router.git
cd tzvi-audio-router
scripts/build.sh
scripts/test.sh
```

The repository is currently private, so cloning requires access. The build creates `build/audioroute`, `build/AudioRoute.app`, and `build/AudioRoute.driver`. Development signatures are ad hoc unless configured otherwise; these are not notarized distribution artifacts.

Install the driver and broker from the Mac account that will use AudioRoute:

```sh
sudo scripts/install-driver.sh
```

Restart the Mac to load the driver, then check and start the background app:

```sh
build/audioroute setup
build/audioroute setup --start
```

Installation needs administrator approval. Capture permissions belong to AudioRoute and are requested when the intended route first needs them. The installer does not restart audio automatically. The explicit development alternative `sudo scripts/activate-driver.sh --yes` restarts Core Audio and interrupts current audio sessions.

Follow the [agent quickstart](agent-quickstart.md) or run `build/audioroute guide` to create a route. Generic templates are in `examples/`; personal scenarios should stay local. The CLI does not change app or system audio selections.

For universal installers and GitHub release signing, see [releasing.md](releasing.md). For test coverage and current implementation boundaries, see [testing.md](testing.md), [verification.md](verification.md), and [cli.md](cli.md).
