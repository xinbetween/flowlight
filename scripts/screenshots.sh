#!/bin/zsh
# Regenerates the marketing screenshots in docs/assets/screenshots/, or another FL_OUT directory.
#
# Every shot is taken from demo data (-FLDemo YES), which lives in its own database, so nothing real is ever
# published. The screen and the window size come from launch arguments rather than synthetic keystrokes: a
# keystroke goes to whichever window is frontmost, which is somebody else's window often enough to matter.
# Set FL_FORCE_SIZE and FL_EXPECT_PIXELS together for a uniform App Store-ready set.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${FL_OUT:-docs/assets/screenshots}"
SIZE="${FL_SIZE:-1600x1075}"
WANT=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
WANT_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)

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
GOT_BUILD=$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)
[ "$GOT" = "$WANT" ] || { echo "$APP is $GOT, project.yml says $WANT — build Release first."; exit 1; }
[ "$GOT_BUILD" = "$WANT_BUILD" ] || {
  echo "$APP is build $GOT_BUILD, project.yml says $WANT_BUILD — build Release first."
  exit 1
}
echo "Shooting Flowlight $GOT ($GOT_BUILD) from $APP"
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
# Rules is Store-capable but not one of the website's ten published assets. Add it only when an explicit capture set
# asks for it, keeping the default website inventory and its all-images manifest stable.
if [ -n "${FL_ONLY:-}" ] && [[ ",${FL_ONLY}," == *",rules,"* ]]; then
  SHOTS+=("rules:rules::")
fi

exact_app_pids() {
  local expected="$1" pid command
  for pid in ${(f)"$(pgrep -x Flowlight 2>/dev/null || true)"}; do
    command=$(ps -p "$pid" -o command=)
    [[ "$command" == "$expected" || "$command" == "$expected "* ]] && print -r -- "$pid"
  done
  # A non-matching installed Flowlight may be the final loop item. Its comparison is not this helper's result:
  # the output is the match set, and an empty set is a successful query rather than a capture failure under pipefail.
  return 0
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

expected_window_title() {
  case "$1" in
    live) print -r -- "Live" ;;
    agents) print -r -- "AI Agents" ;;
    reports) print -r -- "History" ;;
    alerts) print -r -- "Alerts" ;;
    rules) print -r -- "Rules" ;;
    inspect) print -r -- "Inspect" ;;
    visualize) print -r -- "Connections" ;;
    *) echo "    no expected window title for screen $1" >&2; return 1 ;;
  esac
}

title_matches_screen() {
  local screen="$1" actual="$2" expected
  expected=$(expected_window_title "$screen") || return 1
  case "$screen" in
    alerts) [[ "$actual" == "$expected" || "$actual" == "$expected – "* ]] ;;
    rules) [[ "$actual" == "$expected" || "$actual" == "$expected – "*" in force" ]] ;;
    inspect) [[ "$actual" == "$expected" || "$actual" == "$expected – Off" ]] ;;
    *) [[ "$actual" == "$expected" ]] ;;
  esac
}

window_title() {
  scripts/window-id.swift --title "$1"
}

capture() {
  local name="$1" screen="$2" tab="$3" requested_size="$4"
  local size="${FL_FORCE_SIZE:-${requested_size:-$SIZE}}"
  echo "  $name ($screen${tab:+ · $tab})"
  local w="${size%x*}" h="${size#*x}"
  local executable
  executable=$(realpath "$APP/Contents/MacOS/Flowlight")
  [ -z "$(exact_app_pids "$executable")" ] || { echo "    exact candidate is already running"; return 1; }
  # The always-monitor shot asks for the representative "these agents are being monitored" banner, which real
  # inspection state (absent under the demo database) would otherwise never show.
  local banner=() visualization=() rules=()
  [ "$name" = "always-monitor" ] && banner=(-FLDemoBanner YES)
  [ "$name" = "visualize" ] && visualization=(-visualize.mode ai -visualize.presentation map -visualize.granularity hour)
  [ "$name" = "rules" ] && rules=(-FLRulesTab packs)
  # Ignore macOS scene state: this launch is a deterministic fixture, and restored sidebar selection can otherwise
  # arrive after demo seeding and replace the requested screen. Pin English too, so the title check below is stable.
  # Launch the exact executable directly. Launch Services may route arguments between simultaneous installations
  # with the same bundle identifier, producing a real candidate window on the wrong screen.
  "$executable" -ApplePersistenceIgnoreState YES -AppleLanguages "(en)" -AppleLocale en_US \
    -FLDemo YES -FLRenderLive YES -FLScreen "$screen" -FLAgentTab "${tab:-destinations}" \
    -FLWindow "${w}x${h}" -FLInspectSelect paste.example -inspection.enabled NO \
    -FLForceLightAppearance YES -FLPinScreenshotScreen YES \
    "${banner[@]}" "${visualization[@]}" "${rules[@]}" >/dev/null 2>&1 &
  local pid=$!
  local command=""
  for _ in {1..40}; do
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    [[ "$command" == "$executable" || "$command" == "$executable "* ]] && break
    sleep 0.25
  done
  [[ "$command" == "$executable" || "$command" == "$executable "* ]] || {
    echo "    couldn't verify the candidate process"
    return 1
  }
  sleep "${FL_WAIT:-14}"   # seeding 90 days of synthetic history, then the rollups it reads
  # A window that isn't key draws its close/minimise/zoom buttons grey, which is how every published
  # screenshot lost them. Bring the exact candidate forward and let the redraw land before the shutter.
  osascript - "$pid" <<'OSA' >/dev/null 2>&1 || true
on run argv
  tell application "System Events" to set frontmost of first application process whose unix id is (item 1 of argv as integer) to true
end run
OSA
  sleep 2
  local expected actual
  expected=$(expected_window_title "$screen")
  actual=$(window_title "$pid" 2>/dev/null || true)
  if ! title_matches_screen "$screen" "$actual"; then
    echo "    refusing to capture $name: expected $expected, found ${actual:-no window}"
    stop_exact_app "$pid" "$executable"
    return 1
  fi
  local open_files
  open_files=$(lsof -p "$pid" -Fn 2>/dev/null || true)
  if [[ "$open_files" == *traffic.sqlite* || "$open_files" != *demo.sqlite* ]]; then
    echo "    refusing to capture $name: demo.sqlite is not the only traffic database"
    stop_exact_app "$pid" "$executable"
    return 1
  fi
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
  if [ -n "${FL_EXPECT_PIXELS:-}" ]; then
    local expected_width="${FL_EXPECT_PIXELS%x*}" expected_height="${FL_EXPECT_PIXELS#*x}"
    local actual_width actual_height
    actual_width=$(sips -g pixelWidth "$OUT/$name.png" | sed -n 's/.*pixelWidth: //p')
    actual_height=$(sips -g pixelHeight "$OUT/$name.png" | sed -n 's/.*pixelHeight: //p')
    if [ "$actual_width" != "$expected_width" ] || [ "$actual_height" != "$expected_height" ]; then
      echo "    refusing $name: expected ${expected_width}x${expected_height}, captured ${actual_width}x${actual_height}"
      stop_exact_app "$pid" "$executable"
      return 1
    fi
  fi
  if [ "${FL_SKIP_MANIFEST:-NO}" != "YES" ]; then
    python3 scripts/screenshot_manifest.py --directory "$OUT" --version "$GOT" "$name.png"
  fi
  stop_exact_app "$pid" "$executable"
  sleep 2
}

captured=0
for shot in "${SHOTS[@]}"; do
  IFS=":" read -r name screen tab size <<< "$shot"
  if [ -n "${FL_ONLY:-}" ] && [[ ",${FL_ONLY}," != *",${name},"* ]]; then
    continue
  fi
  capture "$name" "$screen" "$tab" "$size"
  captured=$((captured + 1))
done
echo "Wrote $captured screenshots to $OUT"
