#!/bin/bash
# Builds an uninstaller package; never executes its removal script.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' "$project_root/Sources/AudioRouteControl/Version.swift")"
output_dir="$project_root/dist"
unsigned=false
die() { echo "package-uninstaller: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir|--version)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      case "$1" in --output-dir) output_dir="$2";; --version) version="$2";; esac
      shift 2;;
    --unsigned) unsigned=true; shift;;
    --help|-h)
      echo 'Usage: scripts/package-uninstaller.sh [--output-dir DIRECTORY] [--version X.Y.Z] [--unsigned]'
      echo 'Default: Developer ID Installer sign, notarize and staple. Uses the same installer identity and notary credentials as package-release.sh.'
      exit 0;;
    *) die "Unknown argument: $1";;
  esac
done
[[ "$(uname -s)" == Darwin ]] || die "Packaging requires macOS."
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be X.Y.Z."
sign_args=()
if [[ "$unsigned" == false ]]; then
  [[ "${AUDIOROUTE_INSTALLER_SIGN_IDENTITY:-}" == "Developer ID Installer:"* ]] || die "Set AUDIOROUTE_INSTALLER_SIGN_IDENTITY."
  sign_args=(--sign "$AUDIOROUTE_INSTALLER_SIGN_IDENTITY" --timestamp)
  if [[ -n "${AUDIOROUTE_NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$AUDIOROUTE_NOTARY_PROFILE")
  else
    [[ -f "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] || die "Set a notary profile or API key credentials."
    notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  fi
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
suffix=""
[[ "$unsigned" == false ]] || suffix="-unsigned"
package="$output_dir/AudioRoute-$version-uninstaller$suffix.pkg"
[[ ! -e "$package" && ! -e "$package.sha256" ]] || die "Output already exists: $package"
work="$(mktemp -d "${TMPDIR:-/tmp}/audioroute-uninstaller.XXXXXX")"
trap 'rm -rf "$work"' EXIT
/usr/bin/pkgbuild --nopayload --identifier org.audioroute.pkg.uninstaller --version "$version" \
  --scripts "$project_root/packaging/uninstall-scripts" "$work/AudioRoute-remove.pkg"
cat > "$work/Distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Uninstall AudioRoute</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="true" rootVolumeOnly="true" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="14.2"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="remove"/></choices-outline>
  <choice id="remove" visible="false" title="Remove AudioRoute"><pkg-ref id="org.audioroute.pkg.uninstaller"/></choice>
  <pkg-ref id="org.audioroute.pkg.uninstaller" version="$version" onConclusion="None">AudioRoute-remove.pkg</pkg-ref>
</installer-gui-script>
EOF
if [[ "$unsigned" == true ]]; then
  /usr/bin/productbuild --distribution "$work/Distribution.xml" --resources "$project_root/packaging/uninstall-resources" \
    --package-path "$work" "$work/Uninstall.pkg"
else
  /usr/bin/productbuild --distribution "$work/Distribution.xml" --resources "$project_root/packaging/uninstall-resources" \
    --package-path "$work" "${sign_args[@]}" "$work/Uninstall.pkg"
fi
if [[ "$unsigned" == false ]]; then
  /usr/sbin/pkgutil --check-signature "$work/Uninstall.pkg"
  /usr/bin/xcrun notarytool submit "$work/Uninstall.pkg" "${notary_args[@]}" --wait --output-format json > "$work/notarization.json"
  [[ "$(/usr/bin/plutil -extract status raw -o - "$work/notarization.json")" == Accepted ]] || die "Notarization was not accepted."
  /usr/bin/xcrun stapler staple "$work/Uninstall.pkg"
  /usr/bin/xcrun stapler validate "$work/Uninstall.pkg"
  /usr/sbin/spctl --assess --type install --verbose=2 "$work/Uninstall.pkg"
fi
cp "$work/Uninstall.pkg" "$package"
(cd "$output_dir" && /usr/bin/shasum -a 256 "$(basename "$package")" > "$(basename "$package").sha256")
echo "Built $package"
