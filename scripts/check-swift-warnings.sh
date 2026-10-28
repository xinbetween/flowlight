#!/bin/bash
# Fails when an Xcode build log contains a warning attributed to Flowlight's Swift source.
# Toolchain notices (for example, AppIntents metadata extraction) have no project source path and are not release blockers.
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: scripts/check-swift-warnings.sh <xcodebuild-log>" >&2
  exit 2
fi

log=$1
warnings=$(grep -E '^/.*/(Flowlight|FlowlightExtension|FlowlightResponseScriptHelper|Shared)/.*\.swift:[0-9]+:[0-9]+: warning:' "$log" || true)
if [[ -n "$warnings" ]]; then
  echo "Flowlight Swift compiler warnings are release blockers:" >&2
  echo "$warnings" >&2
  exit 1
fi

echo "Flowlight Swift sources are warning-free."
