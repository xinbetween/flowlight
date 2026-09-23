#!/bin/zsh
# Builds Flowlight with the Network Extension entitlements, signed with Developer ID.
# Requires a paid Apple Developer team whose App IDs have the Network Extension capability.
#   TEAM_ID=ABCDE12345 scripts/build-signed.sh
#
# The extension's entitlement (content-filter-provider-systemextension) is only valid in a Developer ID profile, so
# both targets sign manually against profiles downloaded from the developer site. Override the names if yours differ:
#   APP_PROFILE="Flowlight Developer ID" EXT_PROFILE="Flowlight Extension Developer ID"
#
# Developer ID distribution goes through archive + export: with automatic signing, xcodebuild only produces a
# development-signed build, and Xcode creates the Developer ID profiles during the export.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

APP_PROFILE="${APP_PROFILE:-Flowlight Developer ID}"
EXT_PROFILE="${EXT_PROFILE:-Flowlight Extension Developer ID}"
ARCHIVE=build/Flowlight.xcarchive
EXPORT=build/export
OPTIONS=build/export-options.plist
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p build

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.flowlight.app</key><string>$APP_PROFILE</string>
        <key>com.flowlight.app.filter</key><string>$EXT_PROFILE</string>
    </dict>
</dict>
</plist>
PLIST

xcodebuild -project Flowlight.xcodeproj -scheme Flowlight -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  FL_APP_PROFILE="$APP_PROFILE" FL_EXT_PROFILE="$EXT_PROFILE" OTHER_CODE_SIGN_FLAGS="--timestamp" archive

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OPTIONS"

# Notarize the app itself: macOS only loads a system extension from a notarized app, and a stapled ticket means it
# validates without a network round trip. scripts/notarize.sh is a no-op when no credentials are set.
scripts/notarize.sh "$EXPORT/Flowlight.app"

echo "Built: $EXPORT/Flowlight.app"
codesign -dv --verbose=2 "$EXPORT/Flowlight.app" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp" || true
echo "Copy it to /Applications before activating the extension."
