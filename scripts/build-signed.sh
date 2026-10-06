#!/bin/zsh
# Builds Flowlight with the Network Extension entitlements, signed with Developer ID.
# Requires a paid Apple Developer team whose App IDs have the Network Extension capability.
#   TEAM_ID=ABCDE12345 scripts/build-signed.sh
#
# The extension's entitlement (content-filter-provider-systemextension) is only valid in a Developer ID profile, so
# both targets sign manually against profiles downloaded from the developer site. Override the names if yours differ:
#   APP_PROFILE="Flowlight Developer ID" EXT_PROFILE="Flowlight Extension Developer ID"
#
# The archive is the Developer ID artifact. Xcode 26 rejects every export method for this macOS archive containing
# a system extension, so packaging copies the manually signed archive product instead of re-exporting and re-signing it.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

APP_PROFILE="${APP_PROFILE:-Flowlight Developer ID}"
EXT_PROFILE="${EXT_PROFILE:-Flowlight Extension Developer ID}"
ARCHIVE=build/Flowlight.xcarchive
EXPORT=build/export
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p build

xcodebuild -project Flowlight.xcodeproj -scheme Flowlight -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  FL_APP_PROFILE="$APP_PROFILE" FL_EXT_PROFILE="$EXT_PROFILE" OTHER_CODE_SIGN_FLAGS="--timestamp" archive

# The manually signed archive product is already the exact app we distribute. Xcode 26 rejects exportArchive for
# this system-extension archive (including its inferred `development` method), so do not re-export or re-sign it.
mkdir -p "$EXPORT"
cp -R "$ARCHIVE/Products/Applications/Flowlight.app" "$EXPORT/Flowlight.app"

# Notarize the app itself: macOS only loads a system extension from a notarized app, and a stapled ticket means it
# validates without a network round trip. scripts/notarize.sh is a no-op when no credentials are set.
scripts/notarize.sh "$EXPORT/Flowlight.app"

echo "Built: $EXPORT/Flowlight.app"
codesign -dv --verbose=2 "$EXPORT/Flowlight.app" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp" || true
echo "Copy it to /Applications before activating the extension."
