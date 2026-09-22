#!/bin/zsh
# Builds Flowlight with the Network Extension entitlements. Requires a paid Apple Developer
# team that has been granted content-filter-provider-systemextension.
#   TEAM_ID=ABCDE12345 scripts/build-signed.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project Flowlight.xcodeproj -scheme Flowlight -configuration Release -derivedDataPath build \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates build
echo "Copy build/Build/Products/Release/Flowlight.app to /Applications before activating the extension."
