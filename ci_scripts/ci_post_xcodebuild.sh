#!/bin/bash
# Xcode Cloud runs this after every action. Validate the signed Store archive that will be uploaded to TestFlight.
set -euo pipefail

if [[ "${CI_XCODEBUILD_ACTION:-}" != archive ]]; then
  exit 0
fi
: "${CI_ARCHIVE_PATH:?Xcode Cloud did not provide CI_ARCHIVE_PATH for an archive action}"

app="$CI_ARCHIVE_PATH/Products/Applications/Flowlight.app"
if [[ ! -d "$app" ]]; then
  echo "Expected Store archive product at $app" >&2
  exit 1
fi

"$(dirname "$0")/../scripts/check_app_store_product.sh" "$app"
