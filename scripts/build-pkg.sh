#!/bin/zsh
# Builds Flowlight.pkg: installs the app into /Applications.
# Packet capture access is offered by the app on first launch.
#   scripts/build-pkg.sh                 # uses the local ad-hoc build
#   TEAM_ID=… INSTALLER_IDENTITY="Developer ID Installer: …" scripts/build-pkg.sh   # signed release
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${TEAM_ID:-}" ]]; then scripts/build-signed.sh; else scripts/build-local.sh; fi
APP=build/Build/Products/Release/Flowlight.app
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
echo "Built build/Flowlight-$VERSION.pkg"
