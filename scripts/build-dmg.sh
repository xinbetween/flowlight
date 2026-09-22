#!/bin/zsh
# Builds build/Flowlight.dmg: a drag-to-Applications disk image with a branded background.
#
#   scripts/build-dmg.sh                                   # ad-hoc signed app (local testing)
#   TEAM_ID=ABCDE12345 \
#   DMG_SIGN_IDENTITY="Developer ID Application: … (ABCDE12345)" \
#   NOTARY_PROFILE=flowlight-notary scripts/build-dmg.sh   # signed + notarized release
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials flowlight-notary --apple-id … --team-id … --password <app-specific>
#
# The file name has no version so https://github.com/xinbetween/flowlight/releases/latest/download/Flowlight.dmg
# always points at the newest release.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${TEAM_ID:-}" ]]; then scripts/build-signed.sh; else scripts/build-local.sh; fi
APP=build/Build/Products/Release/Flowlight.app
[[ -d "$APP" ]] || { echo "Build failed: $APP missing" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
VOLUME="Flowlight"
WORK=build/dmg
OUT=build/Flowlight.dmg

# Unmount leftovers from an earlier run, then stage the volume contents.
hdiutil info | awk -v v="/Volumes/$VOLUME" '$0 ~ v {print $1}' | while read -r dev; do hdiutil detach "$dev" -force >/dev/null || true; done
rm -rf "$WORK" && mkdir -p "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/Flowlight.app"
ln -s /Applications "$WORK/stage/Applications"
# One multi-resolution TIFF from the 1× and 2× PNGs (regenerate the PNGs with scripts/dmg-background.swift).
tiffutil -cathidpicheck packaging/dmg/background.png packaging/dmg/background@2x.png -out "$WORK/stage/.background/background.tiff" >/dev/null

hdiutil create -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/Apple_HFS/ {print $1; exit}')
MOUNT="/Volumes/$VOLUME"

# Window layout: 660×400 content, icons centred on the background's arrow. Needs Finder automation;
# without it the DMG still works, just with Finder's default layout.
osascript <<OSA || echo "warning: Finder layout skipped (grant Automation access to Finder for the styled window)" >&2
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Flowlight.app" of container window to {170, 198}
    set position of item "Applications" of container window to {490, 198}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

# Custom volume icon (best effort), set after Finder writes its layout. hdiutil drops .VolumeIcon.icns from
# -srcfolder, so it's added to the mounted volume; SetFile ships with the Xcode command-line tools.
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
  if SETFILE=$(xcrun -f SetFile 2>/dev/null); then
    "$SETFILE" -c icnC "$MOUNT/.VolumeIcon.icns" || true
    "$SETFILE" -a C "$MOUNT" || true
  fi
fi

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$DEVICE" >/dev/null
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null

if [[ -n "${DMG_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$DMG_SIGN_IDENTITY" --timestamp "$OUT"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
fi

hdiutil verify "$OUT" >/dev/null
echo "Built $OUT (Flowlight $VERSION, $(du -h "$OUT" | cut -f1))"
