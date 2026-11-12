#!/bin/zsh
# Captures the complete Mac App Store screenshot set from an exact Flowlight Store build.
# FL_APP must point to the reviewed Store product. The shared capture script verifies version,
# screen title, demo-only database use, and exact 2880x1800 output before anything is retained.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${FL_APP:?Set FL_APP to the exact Flowlight App Store build.}"
STORE_EXTENSION="$FL_APP/Contents/PlugIns/com.flowlight.app.filter.appex"
[ -d "$STORE_EXTENSION" ] || {
  echo "$FL_APP is not the App Store product: embedded Store extension is missing."
  exit 1
}
[ ! -e "$FL_APP/Contents/Library/SystemExtensions/com.flowlight.app.filter.systemextension" ] || {
  echo "$FL_APP is the Developer ID product, not the App Store product."
  exit 1
}

OUT="packaging/app-store/screenshots/macos"
TEMP=$(mktemp -d /private/tmp/flowlight-app-store-screenshots.XXXXXX)
cleanup() {
  for image in "$TEMP"/*.png(N); do rm "$image"; done
  rmdir "$TEMP" 2>/dev/null || true
}
trap cleanup EXIT

FL_OUT="$TEMP" \
FL_ONLY="visualize,agents,reports,inspect,rules,live,alerts,agent-detail,agent-tools,mcp-servers" \
FL_FORCE_SIZE="1440x900" \
FL_EXPECT_PIXELS="2880x1800" \
FL_WAIT="${FL_STORE_WAIT:-20}" \
FL_SKIP_MANIFEST="YES" \
scripts/screenshots.sh

mkdir -p "$OUT"
# Remove only the superseded 0.17.x numbered names before writing the complete replacement set.
rm -f "$OUT/04-rules.png" "$OUT/05-live.png" "$OUT/06-alerts.png" \
  "$OUT/07-agent-detail.png" "$OUT/08-agent-tools.png" "$OUT/09-mcp-servers.png"
cp "$TEMP/visualize.png"    "$OUT/01-connections.png"
cp "$TEMP/agents.png"       "$OUT/02-ai-agents.png"
cp "$TEMP/reports.png"      "$OUT/03-history.png"
cp "$TEMP/inspect.png"      "$OUT/04-inspect.png"
cp "$TEMP/rules.png"        "$OUT/05-policies.png"
cp "$TEMP/live.png"         "$OUT/06-live.png"
cp "$TEMP/alerts.png"       "$OUT/07-alerts.png"
cp "$TEMP/agent-detail.png" "$OUT/08-agent-detail.png"
cp "$TEMP/agent-tools.png"  "$OUT/09-agent-tools.png"
cp "$TEMP/mcp-servers.png"  "$OUT/10-mcp-servers.png"

VERSION=$(defaults read "$FL_APP/Contents/Info.plist" CFBundleShortVersionString)
python3 scripts/screenshot_manifest.py --directory "$OUT" --version "$VERSION" --replace \
  01-connections.png 02-ai-agents.png 03-history.png 04-inspect.png 05-policies.png \
  06-live.png 07-alerts.png 08-agent-detail.png 09-agent-tools.png 10-mcp-servers.png

echo "Wrote 10 Mac App Store screenshots to $OUT"
