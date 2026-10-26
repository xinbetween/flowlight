#!/bin/zsh
# Deterministic regression coverage for scripts/notarize.sh's stapler retry policy. No Apple service is contacted.
set -euo pipefail
cd "$(dirname "$0")/.."

temporary=$(mktemp -d "${TMPDIR:-/tmp}/flowlight-notarize-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

fake_bin="$temporary/bin"
mkdir "$fake_bin"

cat > "$fake_bin/sleep" <<'SCRIPT'
#!/bin/zsh
print -r -- "$1" >> "$FLOWLIGHT_TEST_SLEEP_LOG"
SCRIPT

cat > "$fake_bin/ditto" <<'SCRIPT'
#!/bin/zsh
set -euo pipefail
source_path="${@[-2]}"
destination="${@[-1]}"
[[ -d "$source_path" ]]
print -r -- fixture > "$destination"
SCRIPT

cat > "$fake_bin/xcrun" <<'SCRIPT'
#!/bin/zsh
set -euo pipefail
if [[ "$1" == notarytool && "$2" == submit ]]; then
  print -r -- "$*" >> "$FLOWLIGHT_TEST_NOTARY_LOG"
  [[ -f "$3" ]]
  if [[ "$FLOWLIGHT_TEST_MODE" == submit-failure ]]; then
    print -u2 -- 'notary service rejected the upload'
    exit 67
  fi
  exit 0
fi
[[ "$1" == stapler && "$2" == staple ]] || exit 90
attempt=1
[[ -f "$FLOWLIGHT_TEST_COUNT" ]] && attempt=$(( $(< "$FLOWLIGHT_TEST_COUNT") + 1 ))
print -r -- "$attempt" > "$FLOWLIGHT_TEST_COUNT"
case "$FLOWLIGHT_TEST_MODE" in
  immediate)
    print -- 'The staple and validate action worked!'
    ;;
  recover)
    if (( attempt < 3 )); then
      print -u2 -- 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'
      exit 65
    fi
    print -- 'The staple and validate action worked!'
    ;;
  exhaust)
    print -u2 -- 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'
    exit 65
    ;;
  permanent)
    print -u2 -- 'Could not validate ticket: malformed package'
    exit 66
    ;;
  mixed-code)
    print -u2 -- 'Error Domain=NSURLErrorDomain Code=-1001 "The request timed out." context=-1005'
    exit 68
    ;;
  *) exit 91 ;;
esac
SCRIPT
chmod +x "$fake_bin/xcrun" "$fake_bin/sleep" "$fake_bin/ditto"

run_fixture() {
  local mode=$1 case_dir="$temporary/$1"
  mkdir "$case_dir"
  : > "$case_dir/target.dmg"
  : > "$case_dir/notary.log"
  : > "$case_dir/sleep.log"
  PATH="$fake_bin:/usr/bin:/bin" \
    NOTARY_PROFILE=test-profile \
    FLOWLIGHT_TEST_MODE="$mode" \
    FLOWLIGHT_TEST_COUNT="$case_dir/count" \
    FLOWLIGHT_TEST_NOTARY_LOG="$case_dir/notary.log" \
    FLOWLIGHT_TEST_SLEEP_LOG="$case_dir/sleep.log" \
    scripts/notarize.sh "$case_dir/target.dmg"
}

run_fixture immediate > "$temporary/immediate.out" 2>&1
[[ "$(< "$temporary/immediate/count")" == 1 ]]
[[ "$(wc -l < "$temporary/immediate/notary.log" | tr -d ' ')" == 1 ]]
[[ ! -s "$temporary/immediate/sleep.log" ]]

run_fixture recover > "$temporary/recover.out" 2>&1
[[ "$(< "$temporary/recover/count")" == 3 ]]
[[ "$(wc -l < "$temporary/recover/notary.log" | tr -d ' ')" == 1 ]]
[[ "$(< "$temporary/recover/sleep.log")" == $'2\n4' ]]
grep -q 'Notarized and stapled:' "$temporary/recover.out"

set +e
run_fixture exhaust > "$temporary/exhaust.out" 2>&1
fixture_status=$?
set -e
[[ "$fixture_status" == 65 ]] || {
  print -u2 -- "expected persistent -1005 failures to exit 65, got $fixture_status"
  exit 1
}
[[ "$(< "$temporary/exhaust/count")" == 4 ]]
[[ "$(wc -l < "$temporary/exhaust/notary.log" | tr -d ' ')" == 1 ]]
[[ "$(< "$temporary/exhaust/sleep.log")" == $'2\n4\n8' ]]
grep -q 'Stapling failed after 4 attempts' "$temporary/exhaust.out"

set +e
run_fixture permanent > "$temporary/permanent.out" 2>&1
fixture_status=$?
set -e
[[ "$fixture_status" == 66 ]] || {
  print -u2 -- "expected a permanent stapler failure to exit 66, got $fixture_status"
  exit 1
}
[[ "$(< "$temporary/permanent/count")" == 1 ]]
[[ ! -s "$temporary/permanent/sleep.log" ]]
grep -q 'malformed package' "$temporary/permanent.out"

set +e
run_fixture mixed-code > "$temporary/mixed-code.out" 2>&1
fixture_status=$?
set -e
[[ "$fixture_status" == 68 ]] || {
  print -u2 -- "expected a non--1005 URL failure to exit 68, got $fixture_status"
  exit 1
}
[[ "$(< "$temporary/mixed-code/count")" == 1 ]]
[[ ! -s "$temporary/mixed-code/sleep.log" ]]

set +e
run_fixture submit-failure > "$temporary/submit-failure.out" 2>&1
fixture_status=$?
set -e
[[ "$fixture_status" == 67 ]] || {
  print -u2 -- "expected a failed notarization submission to exit 67, got $fixture_status"
  exit 1
}
[[ ! -e "$temporary/submit-failure/count" ]]
[[ "$(wc -l < "$temporary/submit-failure/notary.log" | tr -d ' ')" == 1 ]]

app_case="$temporary/app-submit-failure"
mkdir "$app_case" "$app_case/Flowlight.app"
: > "$app_case/notary.log"
: > "$app_case/sleep.log"
set +e
PATH="$fake_bin:/usr/bin:/bin" \
  TMPDIR="$app_case" \
  NOTARY_PROFILE=test-profile \
  FLOWLIGHT_TEST_MODE=submit-failure \
  FLOWLIGHT_TEST_COUNT="$app_case/count" \
  FLOWLIGHT_TEST_NOTARY_LOG="$app_case/notary.log" \
  FLOWLIGHT_TEST_SLEEP_LOG="$app_case/sleep.log" \
  scripts/notarize.sh "$app_case/Flowlight.app" > "$app_case/output" 2>&1
fixture_status=$?
set -e
[[ "$fixture_status" == 67 ]] || {
  print -u2 -- "expected an app submission failure to exit 67, got $fixture_status"
  exit 1
}
[[ ! -e "$app_case/count" ]]
[[ -z "$(find "$app_case" -maxdepth 1 -type d -name 'flowlight-notarize.*' -print -quit)" ]]

concurrent_case="$temporary/concurrent-apps"
mkdir "$concurrent_case" "$concurrent_case/first" "$concurrent_case/second"
mkdir "$concurrent_case/first/Flowlight.app" "$concurrent_case/second/Flowlight.app"
concurrent_pids=()
for name in first second; do
  : > "$concurrent_case/$name/notary.log"
  : > "$concurrent_case/$name/sleep.log"
  PATH="$fake_bin:/usr/bin:/bin" \
    TMPDIR="$concurrent_case" \
    NOTARY_PROFILE=test-profile \
    FLOWLIGHT_TEST_MODE=immediate \
    FLOWLIGHT_TEST_COUNT="$concurrent_case/$name/count" \
    FLOWLIGHT_TEST_NOTARY_LOG="$concurrent_case/$name/notary.log" \
    FLOWLIGHT_TEST_SLEEP_LOG="$concurrent_case/$name/sleep.log" \
    scripts/notarize.sh "$concurrent_case/$name/Flowlight.app" > "$concurrent_case/$name/output" 2>&1 &
  concurrent_pids+=("$!")
done
for concurrent_pid in "${concurrent_pids[@]}"; do
  wait "$concurrent_pid"
done
first_upload=$(awk '{print $3}' "$concurrent_case/first/notary.log")
second_upload=$(awk '{print $3}' "$concurrent_case/second/notary.log")
[[ "$first_upload" != "$second_upload" ]]
[[ "$first_upload" == "$concurrent_case"/flowlight-notarize.*/Flowlight.zip ]]
[[ "$second_upload" == "$concurrent_case"/flowlight-notarize.*/Flowlight.zip ]]
[[ ! -e "${first_upload:h}" ]]
[[ ! -e "${second_upload:h}" ]]

print -- 'Notarization fixtures passed: immediate success, recovery at 3, exhaustion at 4, permanent and mixed-code failure at 1, submit failure at 0 staples, failed-app cleanup, and isolated concurrent uploads.'
