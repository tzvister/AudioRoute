#!/bin/bash
# Stages copies only. Never installs a package or restarts audio services.
set -euo pipefail
export COPYFILE_DISABLE=1
project_root="$(cd "$(dirname "$0")/.." && pwd)"
artifacts="$project_root/build/release-artifacts"
output_dir="$project_root/dist"
version="${AUDIOROUTE_VERSION:-$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' "$project_root/Sources/AudioRouteControl/Version.swift")}"
unsigned=false
usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh [--artifacts DIRECTORY] [--output-dir DIRECTORY]
                                 [--version X.Y.Z] [--unsigned]

Requires universal arm64 + x86_64 CLI, app, driver, and broker artifacts.
Default: Developer ID sign, notarize, and staple a release package.
  AUDIOROUTE_APP_SIGN_IDENTITY       Developer ID Application identity
  AUDIOROUTE_INSTALLER_SIGN_IDENTITY Developer ID Installer identity
  AUDIOROUTE_NOTARY_PROFILE          notarytool keychain profile, OR all of:
  NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID

--unsigned produces an explicitly labeled development package without
notarization. It is unsuitable for public distribution. No installation occurs.
EOF
}
die() { echo "package-release: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts|--output-dir|--version)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      case "$1" in
        --artifacts) artifacts="$2";;
        --output-dir) output_dir="$2";;
        --version) version="$2";;
      esac
      shift 2;;
    --unsigned) unsigned=true; shift;;
    --help|-h) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done
[[ "$(uname -s)" == Darwin ]] || die "Packaging requires macOS."
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be X.Y.Z."
for tool in /usr/bin/pkgbuild /usr/bin/productbuild /usr/sbin/pkgutil /usr/bin/codesign /usr/bin/lipo; do
  [[ -x "$tool" ]] || die "Required tool missing: $tool"
done
executables=(
  audioroute
  AudioRoute.app/Contents/MacOS/audiorouted
  AudioRoute.driver/Contents/MacOS/AudioRoute
  AudioRoute.driver/Contents/Resources/AudioRouteTransportBroker
)
for executable in "${executables[@]}"; do
  [[ -f "$artifacts/$executable" && -x "$artifacts/$executable" ]] || die "Missing executable: $artifacts/$executable (run scripts/build-release.sh)"
  architectures="$(/usr/bin/lipo -archs "$artifacts/$executable")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || die "$executable is not universal (found: $architectures)."
  for architecture in $architectures; do
    [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || die "Unsupported architecture $architecture in $executable."
  done
done
actual_version="$("$artifacts/audioroute" --version)"
[[ "$actual_version" == "audioroute $version" ]] || die "CLI version ($actual_version) does not match package $version."
for executable in "${executables[@]}"; do
  build_info="$(/usr/bin/xcrun vtool -show-build "$artifacts/$executable")"
  [[ "$(printf '%s\n' "$build_info" | awk '/minos / {n++} END {print n+0}')" == 2 ]] || die "Could not verify both deployment targets in $executable."
  while IFS= read -r minimum; do
    [[ "$minimum" == 14.2 || "$minimum" == 14.0 || "$minimum" == 14 ]] || die "$executable requires macOS $minimum; expected compatibility with 14.2."
  done < <(printf '%s\n' "$build_info" | awk '/minos / {print $2}')
done
if [[ "$unsigned" == false ]]; then
  [[ "${AUDIOROUTE_APP_SIGN_IDENTITY:-}" == "Developer ID Application:"* ]] || die "Set AUDIOROUTE_APP_SIGN_IDENTITY to a Developer ID Application identity."
  [[ "${AUDIOROUTE_INSTALLER_SIGN_IDENTITY:-}" == "Developer ID Installer:"* ]] || die "Set AUDIOROUTE_INSTALLER_SIGN_IDENTITY to a Developer ID Installer identity."
  if [[ -n "${AUDIOROUTE_NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$AUDIOROUTE_NOTARY_PROFILE")
  else
    [[ -f "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] || die "Set AUDIOROUTE_NOTARY_PROFILE or all three NOTARY_KEY_* / NOTARY_ISSUER_ID values."
    notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  fi
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
suffix=""
[[ "$unsigned" == false ]] || suffix="-unsigned"
package="$output_dir/AudioRoute-$version-universal$suffix.pkg"
[[ ! -e "$package" && ! -e "$package.sha256" ]] || die "Output already exists: $package"
work="$(mktemp -d "${TMPDIR:-/tmp}/audioroute-package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
payload="$work/payload"
mkdir -p "$payload/Applications" "$payload/usr/local/bin" "$payload/Library/Audio/Plug-Ins/HAL" "$payload/Library/LaunchDaemons"
/usr/bin/ditto "$artifacts/AudioRoute.app" "$payload/Applications/AudioRoute.app"
/usr/bin/ditto "$artifacts/AudioRoute.driver" "$payload/Library/Audio/Plug-Ins/HAL/AudioRoute.driver"
/usr/bin/install -m 755 "$artifacts/audioroute" "$payload/usr/local/bin/audioroute"
/usr/bin/install -m 644 "$project_root/Driver/org.audioroute.transport.plist" "$payload/Library/LaunchDaemons/org.audioroute.transport.plist"
app="$payload/Applications/AudioRoute.app"
driver="$payload/Library/Audio/Plug-Ins/HAL/AudioRoute.driver"
for bundle in "$app" "$driver"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$bundle/Contents/Info.plist"
done
if [[ "$unsigned" == true ]]; then
  # Locally runnable artifacts still need ad hoc signatures on Apple silicon.
  sign_args=(--force --sign -)
else
  sign_args=(--force --sign "$AUDIOROUTE_APP_SIGN_IDENTITY" --options runtime --timestamp)
fi
/usr/bin/codesign "${sign_args[@]}" --identifier org.audioroute.cli "$payload/usr/local/bin/audioroute"
/usr/bin/codesign "${sign_args[@]}" --identifier org.audioroute.transport-broker "$driver/Contents/Resources/AudioRouteTransportBroker"
/usr/bin/codesign "${sign_args[@]}" "$driver"
/usr/bin/codesign "${sign_args[@]}" --entitlements "$project_root/packaging/AudioRoute.entitlements" "$app"
for signed_path in "$payload/usr/local/bin/audioroute" "$driver/Contents/Resources/AudioRouteTransportBroker" "$driver" "$app"; do
  /usr/bin/codesign --verify --strict "$signed_path"
done
# Fixed paths prevent Installer from finding and overwriting the running build app.
cat > "$work/components.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array>
<dict><key>RootRelativeBundlePath</key><string>Applications/AudioRoute.app</string><key>BundleIsRelocatable</key><false/><key>BundleIsVersionChecked</key><false/><key>BundleHasStrictIdentifier</key><true/><key>BundleOverwriteAction</key><string>upgrade</string></dict>
<dict><key>RootRelativeBundlePath</key><string>Library/Audio/Plug-Ins/HAL/AudioRoute.driver</string><key>BundleIsRelocatable</key><false/><key>BundleIsVersionChecked</key><false/><key>BundleHasStrictIdentifier</key><true/><key>BundleOverwriteAction</key><string>upgrade</string></dict>
</array></plist>
EOF
/usr/bin/pkgbuild --root "$payload" --install-location / --ownership recommended \
  --identifier org.audioroute.pkg.core --version "$version" \
  --component-plist "$work/components.plist" --scripts "$project_root/packaging/scripts" "$work/AudioRoute-core.pkg"
cat > "$work/Distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>AudioRoute $version</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="true" rootVolumeOnly="true" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="14.2"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" visible="false" title="AudioRoute"><pkg-ref id="org.audioroute.pkg.core"/></choice>
  <pkg-ref id="org.audioroute.pkg.core" version="$version" onConclusion="None">AudioRoute-core.pkg</pkg-ref>
</installer-gui-script>
EOF
mkdir -p "$work/resources"
cp "$project_root/packaging/resources/"*.html "$work/resources/"
if [[ "$unsigned" == true ]]; then
  /usr/bin/sed -i '' 's/AudioRoute installation/AudioRoute unsigned development installation/' "$work/resources/welcome.html"
fi
if [[ "$unsigned" == true ]]; then
  /usr/bin/productbuild --distribution "$work/Distribution.xml" --resources "$work/resources" --package-path "$work" "$work/AudioRoute.pkg"
else
  /usr/bin/productbuild --distribution "$work/Distribution.xml" --resources "$work/resources" --package-path "$work" --sign "$AUDIOROUTE_INSTALLER_SIGN_IDENTITY" --timestamp "$work/AudioRoute.pkg"
fi
if [[ "$unsigned" == false ]]; then
  /usr/sbin/pkgutil --check-signature "$work/AudioRoute.pkg"
  /usr/bin/xcrun notarytool submit "$work/AudioRoute.pkg" "${notary_args[@]}" --wait --output-format json > "$work/notarization.json"
  status="$(/usr/bin/plutil -extract status raw -o - "$work/notarization.json")"
  if [[ "$status" != Accepted ]]; then
    cat "$work/notarization.json" >&2
    die "Notarization was not accepted; no release package was produced."
  fi
  /usr/bin/xcrun stapler staple "$work/AudioRoute.pkg"
  /usr/bin/xcrun stapler validate "$work/AudioRoute.pkg"
  /usr/sbin/spctl --assess --type install --verbose=2 "$work/AudioRoute.pkg"
  cp "$work/notarization.json" "$output_dir/AudioRoute-$version-universal.notarization.json"
fi
cp "$work/AudioRoute.pkg" "$package"
(cd "$output_dir" && /usr/bin/shasum -a 256 "$(basename "$package")" > "$(basename "$package").sha256")
echo "Built $package"
if [[ "$unsigned" == true ]]; then echo "Unsigned development package: do not publish as a trusted release."; fi
