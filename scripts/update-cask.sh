#!/usr/bin/env bash
# Updates packaging/homebrew/flowlight.rb to the current version and the DMG's checksum, then copies it into the
# Homebrew tap so `brew install --cask xinbetween/tap/flowlight` gets the new release.
#
#   scripts/update-cask.sh                 # version from project.yml, checksum from build/Flowlight.dmg
#   VERSION=0.2.1 scripts/update-cask.sh   # no local build: checksum from the published release
#   REQUIRE_LOCAL_DMG=1 scripts/update-cask.sh  # CI: refuse a fallback download
#   TAP=/path/to/homebrew-tap scripts/update-cask.sh
#
# Without TAP it uses the tap Homebrew already has checked out, and only copies the file — pushing is yours to do.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION:[[:space:]]*"\(.*\)".*/\1/p' project.yml)}"
CASK="${CASK_PATH:-packaging/homebrew/flowlight.rb}"
LOCAL_DMG="${DMG_PATH:-build/Flowlight.dmg}"
sha256_file() {
  python3 -I - "$1" <<'PY'
import hashlib
import pathlib
import sys

value = hashlib.sha256()
with pathlib.Path(sys.argv[1]).open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(chunk)
print(value.hexdigest())
PY
}

if [[ -f "$LOCAL_DMG" ]]; then
  SHA=$(sha256_file "$LOCAL_DMG")
  echo "Checksum from $LOCAL_DMG"
elif [[ -n "${REQUIRE_LOCAL_DMG:-}" ]]; then
  echo "REQUIRE_LOCAL_DMG is set, but $LOCAL_DMG is missing." >&2
  exit 1
else
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/Flowlight.dmg" "https://github.com/xinbetween/flowlight/releases/download/v$VERSION/Flowlight.dmg"
  SHA=$(sha256_file "$TMP/Flowlight.dmg")
  rm -rf "$TMP"
  echo "Checksum from the published v$VERSION DMG"
fi

python3 -I - "$CASK" "$VERSION" "$SHA" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text, versions = re.subn(r'^  version ".*"$', f'  version "{sys.argv[2]}"', text, count=1, flags=re.MULTILINE)
text, checksums = re.subn(r'^  sha256 ".*"$', f'  sha256 "{sys.argv[3]}"', text, count=1, flags=re.MULTILINE)
if versions != 1 or checksums != 1:
    raise SystemExit("cask must contain exactly one version and one sha256 declaration")
path.write_text(text)
PY
echo "$CASK → version $VERSION, sha256 $SHA"

# Homebrew refuses to lint a cask outside a tap, so both checks run on the tap's copy.
if [[ -z "${TAP:-}" ]] && command -v brew >/dev/null; then
  TAP=$(brew --repository xinbetween/tap 2>/dev/null || true)
  [[ -d "$TAP" ]] || TAP=""
fi
[[ -n "${TAP:-}" ]] || { echo "No tap checked out; run: brew tap xinbetween/tap"; exit 0; }

mkdir -p "$TAP/Casks"
cp "$CASK" "$TAP/Casks/flowlight.rb"
echo "Copied to $TAP/Casks/flowlight.rb"
if command -v brew >/dev/null && [[ "$TAP" == "$(brew --repository xinbetween/tap 2>/dev/null)" ]]; then
  brew style --cask xinbetween/tap/flowlight
  brew audit --cask --online xinbetween/tap/flowlight
else
  echo "Skipping brew style/audit: $TAP isn't Homebrew's own checkout of the tap."
fi
if [[ -d "$TAP/.git" ]]; then
  git -C "$TAP" add Casks/flowlight.rb
  if git -C "$TAP" diff --cached --quiet; then
    echo "The tap already has Flowlight $VERSION; no commit needed."
  else
    git -C "$TAP" commit -m "flowlight $VERSION" >/dev/null
    echo "Committed in $TAP — push it to publish."
  fi
fi
