#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
gate="$script_dir/check-codeql-gate.sh"

run_gate() {
  env \
    CLASSIFY_RESULT="$1" \
    SWIFT_ROUTE="$2" PYTHON_ROUTE="$3" ACTIONS_ROUTE="$4" \
    SWIFT_RESULT="$5" PYTHON_RESULT="$6" ACTIONS_RESULT="$7" \
    "$gate"
}

expect_failure() {
  local label=$1
  shift
  if run_gate "$@" >/dev/null 2>&1; then
    echo "FAIL: $label was accepted"
    exit 1
  fi
}

run_gate success true false false success skipped skipped
run_gate success true true true success success success
expect_failure "failed classifier" failure true true true success success success
expect_failure "failed routed analyzer" success true false false failure skipped skipped
expect_failure "missing routed analyzer" success true false false skipped skipped skipped
expect_failure "malformed route" success maybe false false success skipped skipped

echo "CodeQL gate policy fixtures passed."
