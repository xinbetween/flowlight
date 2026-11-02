#!/bin/zsh
# Regenerates the marketing screenshots in docs/assets/screenshots/.
#
# Every shot is taken from demo data (-FLDemo YES), which lives in its own database, so nothing real is ever
# published. The screen and the window size come from launch arguments rather than synthetic keystrokes: a
# keystroke goes to whichever window is frontmost, which is somebody else's window often enough to matter.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="docs/assets/screenshots"
SIZE="${FL_SIZE:-1600x1075}"
WANT=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)

# Ask xcodebuild where it actually put the app. A hard-coded build/ path is how these screenshots were once
# taken from a months-old bundle: it existed, it launched, and nothing said it was the wrong version.
if [ -z "${FL_APP:-}" ]; then
  PRODUCTS=$(xcodebuild -project Flowlight.xcodeproj -scheme Flowlight -configuration Release     -showBuildSettings 2>/dev/null | sed -n 's/.*BUILT_PRODUCTS_DIR = //p' | head -1)
  APP="$PRODUCTS/Flowlight.app"
else
  APP="$FL_APP"
fi
[ -d "$APP" ] || { echo "No app at $APP — build Release first."; exit 1; }

GOT=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
[ "$GOT" = "$WANT" ] || { echo "$APP is $GOT, project.yml says $WANT — build Release first."; exit 1; }
echo "Shooting Flowlight $GOT from $APP"
mkdir -p "$OUT"

# name:screen:agent-tab:height — a couple of shots are taller or shorter than the default.
SHOTS=(
  "live:live::"
  "agents:agents:destinations:"
  "always-monitor:agents:destinations:"
  "agent-detail:agents:calls:"
  "agent-tools:agents:tools:1600x622"
  "mcp-servers:agents:servers:1600x622"
  "reports:reports::"
  "alerts:alerts::"
  "inspect:inspect::"
  "visualize:visualize::1600x994"
)

exact_app_pids() {
  local expected="$1" pid command
  for pid in ${(f)"$(pgrep -x Flowlight 2>/dev/null || true)"}; do
    command=$(ps -p "$pid" -o command=)
    [[ "$command" == "$expected" || "$command" == "$expected "* ]] && print -r -- "$pid"
  done
}

stop_exact_app() {
  local pid="$1" expected="$2" command
  command=$(ps -p "$pid" -o command=)
  if [[ "$command" == "$expected" || "$command" == "$expected "* ]]; then
    kill -TERM "$pid"
  else
    echo "    refusing to stop PID $pid: executable changed"
    return 1
  fi
}

capture() {
  local name="$1" screen="$2" tab="$3" size="${4:-$SIZE}"
  echo "  $name ($screen${tab:+ · $tab})"
  local w="${size%x*}" h="${size#*x}"
  local executable
  executable=$(realpath "$APP/Contents/MacOS/Flowlight")
  [ -z "$(exact_app_pids "$executable")" ] || { echo "    exact candidate is already running"; return 1; }
  # The always-monitor shot asks for the representative "these agents are being monitored" banner, which real
  # inspection state (absent under the demo database) would otherwise never show.
  local banner=() visualization=()
  [ "$name" = "always-monitor" ] && banner=(-FLDemoBanner YES)
  [ "$name" = "visualize" ] && visualization=(-visualize.mode ai -visualize.presentation map -visualize.granularity hour)
  open -n "$APP" --args -FLDemo YES -FLScreen "$screen" -FLAgentTab "${tab:-destinations}" \
    -FLWindow "${w}x${h}" -FLInspectSelect paste.example "${banner[@]}" "${visualization[@]}"
  local pid=""
  for _ in {1..40}; do
    pid=$(exact_app_pids "$executable" | head -1)
    [ -n "$pid" ] && break
    sleep 0.25
  done
  [ -n "$pid" ] || { echo "    couldn't find the candidate process"; return 1; }
  sleep "${FL_WAIT:-14}"   # seeding 90 days of synthetic history, then the rollups it reads
  # A window that isn't key draws its close/minimise/zoom buttons grey, which is how every published
  # screenshot lost them. Bring the exact candidate forward and let the redraw land before the shutter.
  osascript - "$pid" <<'OSA' >/dev/null 2>&1 || true
on run argv
  tell application "System Events" to set frontmost of first application process whose unix id is (item 1 of argv as integer) to true
end run
OSA
  sleep 2
  local id
  id=$(scripts/window-id.swift "$pid" 2>/dev/null || true)
  if [ -z "$id" ]; then
    echo "    couldn't find the candidate window"
    stop_exact_app "$pid" "$executable"
    return 1
  fi
  if ! screencapture -x -o -l"$id" "$OUT/$name.png"; then
    stop_exact_app "$pid" "$executable"
    return 1
  fi
  stop_exact_app "$pid" "$executable"
  sleep 2
}

for shot in "${SHOTS[@]}"; do
  IFS=":" read -r name screen tab size <<< "$shot"
  capture "$name" "$screen" "$tab" "$size"
done
echo "Wrote ${#SHOTS[@]} screenshots to $OUT"
