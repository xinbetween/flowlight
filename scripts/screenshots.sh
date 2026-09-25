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
  "agent-detail:agents:calls:"
  "agent-tools:agents:tools:1600x622"
  "mcp-servers:agents:servers:1600x622"
  "reports:reports::"
  "alerts:alerts::"
  "inspect:inspect::"
)

capture() {
  local name="$1" screen="$2" tab="$3" size="${4:-$SIZE}"
  echo "  $name ($screen${tab:+ · $tab})"
  local w="${size%x*}" h="${size#*x}"
  open -n "$APP" --args -FLDemo YES -FLScreen "$screen" -FLAgentTab "${tab:-destinations}" \
    -FLWindow "${w}x${h}" -FLInspectSelect paste.example
  sleep "${FL_WAIT:-14}"   # seeding 90 days of synthetic history, then the rollups it reads
  local id
  id=$(scripts/window-id.swift 2>/dev/null || true)
  if [ -z "$id" ]; then echo "    couldn't find the window"; osascript -e 'quit app "Flowlight"'; return 1; fi
  screencapture -x -o -l"$id" "$OUT/$name.png"
  osascript -e 'quit app "Flowlight"' >/dev/null 2>&1 || true
  sleep 2
}

osascript -e 'quit app "Flowlight"' >/dev/null 2>&1 || true
sleep 1

# The demo database is seeded relative to the moment it is written, so one left over from another day has
# nothing inside the windows these views ask about — which is how a run produced eight empty screens. It is
# synthetic and rebuilt on launch, so throwing it away costs nothing.
rm -f "$HOME/Library/Application Support/Flowlight/demo.sqlite"*

for shot in "${SHOTS[@]}"; do
  IFS=":" read -r name screen tab size <<< "$shot"
  capture "$name" "$screen" "$tab" "$size"
done
echo "Wrote ${#SHOTS[@]} screenshots to $OUT"
