# Releasing AudioRoute for macOS

The release artifact is one universal `.pkg` containing `/usr/local/bin/audioroute`, `/Applications/AudioRoute.app`, the HAL plug-in, and its LaunchDaemon. Installation uses macOS Installer's administrator authorization. No build tools are required on the user's machine. Scripts never restart Core Audio or request capture permission. Restart after installation/update before first use, then run `audioroute setup` and `audioroute setup --start`.

## Current readiness

Universal payload and unsigned installer assembly have been tested locally. The package was expanded and inspected without installation. Developer ID signing, notarization, a fresh-machine installation, and Intel audio behavior remain unverified. Do not publish the unsigned package as a trusted release. The repository is [tzvister/tzvi-audio-router](https://github.com/tzvister/tzvi-audio-router) and is private. Apple signing credentials have not been configured.

## Build and inspect locally

```sh
scripts/build-release.sh
scripts/package-release.sh --unsigned --output-dir build/installer-check
python3 scripts/test-release-package.py build/installer-check/AudioRoute-0.1.0-universal-unsigned.pkg
```

The build uses separate architecture scratch directories and does not overwrite the running development app. Packaging stages copies, checks architecture/minimum OS/version, signs those copies, and creates a checksum. It refuses to overwrite an existing package. Tests inspect payload paths, versions, root ownership, architecture slices, signatures and installer script syntax; they never execute installer scripts.

## Signed distribution

Apple's distribution process requires Developer ID code signing and notarization for the intended Gatekeeper experience: [Developer ID](https://developer.apple.com/developer-id/), [package signing](https://help.apple.com/xcode/mac/current/en.lproj/deve51ce7c3d.html), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Set `AUDIOROUTE_APP_SIGN_IDENTITY` to a Developer ID Application identity and `AUDIOROUTE_INSTALLER_SIGN_IDENTITY` to a Developer ID Installer identity in your keychain. Supply `AUDIOROUTE_NOTARY_PROFILE` for an existing notarytool keychain profile, or `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` for an App Store Connect team API key. Keep private keys and passwords outside the repository.

Run `scripts/package-release.sh` without `--unsigned`. It signs the binaries and bundles with hardened runtime, signs the installer, submits it using notarytool, requires Accepted status, staples the ticket, and checks Gatekeeper assessment before producing `dist/AudioRoute-VERSION-universal.pkg` and its SHA-256 checksum. A failed signing/notarization step does not produce a publishable output package.

## GitHub Actions

`.github/workflows/release.yml` runs on `vMAJOR.MINOR.PATCH` tags or a manual existing tag. Before tagging, bump `Sources/AudioRouteControl/Version.swift`; the build rejects a tag/version mismatch. The tag must be on the repository default branch's history. The workflow tests before importing credentials, builds both architecture slices on the native arm64 runner, packages/signs/notarizes, and attaches assets to a **draft** GitHub Release. It refuses to replace an already-published release. Review and publish after clean-machine checks.

Repository secrets:

| Secret | Value |
| --- | --- |
| `APP_CERTIFICATE_P12_BASE64` | Base64 Developer ID Application certificate and private key export |
| `APP_CERTIFICATE_PASSWORD` | Export password |
| `INSTALLER_CERTIFICATE_P12_BASE64` | Base64 Developer ID Installer certificate and private key export |
| `INSTALLER_CERTIFICATE_PASSWORD` | Export password |
| `AUDIOROUTE_APP_SIGN_IDENTITY` | Full Developer ID Application identity |
| `AUDIOROUTE_INSTALLER_SIGN_IDENTITY` | Full Developer ID Installer identity |
| `NOTARY_KEY_P8_BASE64` | Base64 App Store Connect team API private key |
| `NOTARY_KEY_ID` | API key ID |
| `NOTARY_ISSUER_ID` | Team issuer ID |

Signing material is imported into a temporary runner keychain and cleaned up afterward. The workflow does not expose secrets to pull-request triggers. Configure tag protection and restrict who can change the release workflow. The runner choice follows [GitHub's macOS runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Before public release

Install the signed, stapled package through Finder on clean Apple Silicon and Intel Macs running supported macOS. Verify the welcome/conclusion pages, first admin prompt, restart/loading behavior, normal PATH invocation, setup diagnostics, capture permission ownership, actual audio, upgrades preserving saved routes, and the single-account restriction. Test a real remote lesson. No clean-machine or signed-distribution result should be inferred from the local unsigned package inspection.

The shared registry currently belongs to the signed-in routing account. Existing user-owned state is verified and preserved by the installer; it is not recursively re-owned by root. Fast user switching/multi-user routing is not supported. A package upgrade requires a restart before using the new driver and background app together.
