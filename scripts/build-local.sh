#!/bin/zsh
# Builds an ad-hoc signed Flowlight.app WITHOUT restricted entitlements.
# Runs on any Mac using the nettop fallback; the embedded extension cannot be activated.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Flowlight.xcodeproj -scheme Flowlight -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= build
echo "Built: build/Build/Products/Release/Flowlight.app"
