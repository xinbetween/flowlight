#!/bin/zsh
# Collects what's needed to work out why capture isn't producing anything, and prints it for pasting into an issue.
#
#   curl -fsSL https://raw.githubusercontent.com/xinbetween/flowlight/main/scripts/diagnose.sh | zsh
#
# It reads state and counts only. No hostnames, addresses, app names or anything Flowlight recorded about your
# traffic is printed — check the source above before running it, and read the output before you paste it.
set -uo pipefail

echo "=== Flowlight diagnostics ==="
echo "date: $(date '+%F %T %Z')"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
echo

echo "--- app ---"
if [[ -d /Applications/Flowlight.app ]]; then
  echo "version: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Flowlight.app/Contents/Info.plist 2>/dev/null)"
  echo "signature: $(codesign -dv --verbose=2 /Applications/Flowlight.app 2>&1 | grep -E '^Authority=|^TeamIdentifier=' | tr '\n' ' ')"
  echo "gatekeeper: $(spctl -a -vvv /Applications/Flowlight.app 2>&1 | head -2 | tr '\n' ' ')"
else
  echo "not installed in /Applications"
fi
echo "running: $(pgrep -f '/Applications/Flowlight.app/Contents/MacOS/Flowlight' | tr '\n' ' ')"
echo "capture source: $(defaults read com.flowlight.app capture.mode 2>/dev/null || echo '(default)')"
echo

echo "--- system extension ---"
systemextensionsctl list 2>&1 | grep -E 'flowlight|enabled|extension\(s\)' || echo "none"
echo "provider process: $(pgrep -f 'com.flowlight.app.filter' | tr '\n' ' ' || echo 'NOT RUNNING')"
echo

echo "--- what the filter reports (last 30 minutes) ---"
# "Filter started" means macOS accepted the filter. The per-minute line says whether it is being handed any flows:
# flows seen at zero means macOS isn't routing traffic through it, which is a different problem from not connecting.
# /usr/bin/log spelled out: zsh has a `log` builtin that shadows it and fails with "too many arguments".
FILTER_LOG=$(/usr/bin/log show --last 30m --info --predicate 'subsystem == "com.flowlight.app.filter"' --style compact 2>/dev/null \
  | grep -v '^Timestamp' | tail -15)
if [[ -n "$FILTER_LOG" ]]; then
  print -r -- "$FILTER_LOG"
else
  echo "(nothing logged — the extension may never have started filtering)"
fi
echo

echo "--- database ---"
DB="$HOME/Library/Application Support/Flowlight/traffic.sqlite"
if [[ -f "$DB" ]]; then
  echo "size: $(du -h "$DB" | cut -f1)"
  if command -v sqlite3 >/dev/null; then
    WORK=$(mktemp -d)
    cp "$DB" "$WORK/db.sqlite" 2>/dev/null
    cp "$DB-wal" "$WORK/db.sqlite-wal" 2>/dev/null
    echo "rows in the last 5 minutes: $(sqlite3 "$WORK/db.sqlite" "SELECT COUNT(*) FROM flows_1s WHERE ts > strftime('%s','now') - 300;" 2>/dev/null)"
    echo "newest row: $(sqlite3 "$WORK/db.sqlite" "SELECT datetime(MAX(ts),'unixepoch','localtime') FROM flows_1s;" 2>/dev/null)"
    rm -rf "$WORK"
  fi
else
  echo "no database yet"
fi
echo
echo "=== end ==="
