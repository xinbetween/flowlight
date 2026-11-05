#!/bin/bash
# One fail-capable macOS test harness shared by both supported Xcode jobs.
set -uo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must name the runner temporary directory}"

# xcodebuild occasionally never returns here. Per-test allowances do not catch every test-host hang, so the whole
# invocation gets a watchdog. A hang that clears on one retry is a visible flake; one that repeats fails the job.
run_tests() {
  local log="$1" limit=900
  xcodebuild test -project Flowlight.xcodeproj -scheme Flowlight -destination 'platform=macOS' \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 300 \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= > "$log" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      echo "::warning::xcodebuild still running after ${limit}s — killing it."
      kill -9 "$pid" 2>/dev/null
      pkill -9 -f "xcodebuild|XCTestCore|testmanagerd" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 5
    waited=$((waited + 5))
  done
  wait "$pid"
}

log="$RUNNER_TEMP/test.log"
run_tests "$log"
status=$?
grep -E "Test Case .* (passed|failed)|Executed .* tests|\*\* TEST" "$log" | tail -25

if [ "$status" -eq 124 ]; then
  echo "::group::Where it stopped (last 60 lines before the kill)"
  tail -60 "$log"
  echo "::endgroup::"
  echo "Retrying once."
  log="$RUNNER_TEMP/test-retry.log"
  run_tests "$log"
  status=$?
  grep -E "Executed .* tests|\*\* TEST" "$log" | tail -10
fi

if [ "$status" -ne 0 ]; then
  echo "::group::Last 300 lines"
  tail -300 "$log"
  echo "::endgroup::"
  echo "Why it failed (status $status):"
  # Outside the group, so it is the first thing visible on a failed run.
  grep -E "error:|Testing failed:|XCTAssert.*failed|exceeded execution time allowance" "$log" | head -40
  exit 1
fi

scripts/check-swift-warnings.sh "$log"
