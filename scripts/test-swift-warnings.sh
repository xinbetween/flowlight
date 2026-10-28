#!/bin/bash
# Deterministic coverage for the first-party Swift warning gate. No Xcode build is required.
set -euo pipefail
cd "$(dirname "$0")/.."

temporary=$(mktemp -d "${TMPDIR:-/tmp}/flowlight-swift-warnings-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

cat > "$temporary/clean.log" <<'LOG'
2026-10-26 appintentsmetadataprocessor[1:2] warning: Metadata extraction skipped, no AppIntents.framework dependency found
/tmp/dependency/Sources/Library.swift:10:3: warning: dependency warning outside Flowlight source
** BUILD SUCCEEDED **
LOG
scripts/check-swift-warnings.sh "$temporary/clean.log"

cat > "$temporary/dirty.log" <<'LOG'
/tmp/checkout/Flowlight/Analysis/RuleStore.swift:412:90: warning: actor-isolated property used from nonisolated context
** BUILD SUCCEEDED **
LOG
if scripts/check-swift-warnings.sh "$temporary/dirty.log" > "$temporary/output" 2>&1; then
  echo "first-party Swift warning was not rejected" >&2
  exit 1
fi
grep -Fq 'RuleStore.swift:412:90: warning:' "$temporary/output"

echo "Swift warning fixtures passed: toolchain and dependency notices allowed, first-party warning rejected."
