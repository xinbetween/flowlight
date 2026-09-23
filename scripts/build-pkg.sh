#!/bin/zsh
# Builds Flowlight.pkg: installs the app into /Applications.
# Packet capture access is offered by the app on first launch.
#   scripts/build-pkg.sh                 # uses the local ad-hoc build
#   TEAM_ID=… INSTALLER_IDENTITY="Developer ID Installer: …" scripts/build-pkg.sh   # signed release
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${TEAM_ID:-}" ]]; then scripts/build-signed.sh; else scripts/build-local.sh; fi
# Prefer the Developer ID build exported by build-signed.sh; fall back to the ad-hoc local build.
APP=build/export/Flowlight.app
[[ -d "$APP" ]] || APP=build/Build/Products/Release/Flowlight.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
WORK=build/pkg
export COPYFILE_DISABLE=1          # no ._ AppleDouble files in the payload
rm -rf "$WORK" && mkdir -p "$WORK/root"
cp -R "$APP" "$WORK/root/"

# Always install to /Applications (don't "upgrade" a copy found elsewhere, e.g. in build/).
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/components.plist"

pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --install-location /Applications \
  --identifier com.flowlight.app.pkg --version "$VERSION" "$WORK/Flowlight-component.pkg"

SIGN=()
[[ -n "${INSTALLER_IDENTITY:-}" ]] && SIGN=(--sign "$INSTALLER_IDENTITY")
productbuild --package "$WORK/Flowlight-component.pkg" --identifier com.flowlight.app.installer --version "$VERSION" \
  "${SIGN[@]}" "build/Flowlight-$VERSION.pkg"

# A signed installer still needs notarizing, or macOS refuses to open it.
if [[ -n "${NOTARY_PROFILE:-}" && ${#SIGN[@]} -gt 0 ]]; then
  xcrun notarytool submit "build/Flowlight-$VERSION.pkg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "build/Flowlight-$VERSION.pkg"
fi
echo "Built build/Flowlight-$VERSION.pkg"
