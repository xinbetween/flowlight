#!/bin/zsh
# Updates packaging/homebrew/flowlight.rb to the current version and the DMG's checksum, then copies it into the
# Homebrew tap so `brew install --cask xinbetween/tap/flowlight` gets the new release.
#
#   scripts/update-cask.sh                 # version from project.yml, checksum from build/Flowlight.dmg
#   VERSION=0.2.1 scripts/update-cask.sh   # no local build: checksum from the published release
#   TAP=/path/to/homebrew-tap scripts/update-cask.sh
#
# Without TAP it uses the tap Homebrew already has checked out, and only copies the file — pushing is yours to do.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION:[[:space:]]*"\(.*\)".*/\1/p' project.yml)}"
CASK=packaging/homebrew/flowlight.rb

if [[ -f build/Flowlight.dmg ]]; then
  SHA=$(shasum -a 256 build/Flowlight.dmg | cut -d' ' -f1)
  echo "Checksum from build/Flowlight.dmg"
else
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/Flowlight.dmg" "https://github.com/xinbetween/flowlight/releases/download/v$VERSION/Flowlight.dmg"
  SHA=$(shasum -a 256 "$TMP/Flowlight.dmg" | cut -d' ' -f1)
  rm -rf "$TMP"
  echo "Checksum from the published v$VERSION DMG"
fi

/usr/bin/sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
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
if command -v brew >/dev/null; then
  brew style --cask xinbetween/tap/flowlight
  brew audit --cask --online xinbetween/tap/flowlight
fi
if [[ -d "$TAP/.git" ]]; then
  git -C "$TAP" add Casks/flowlight.rb
  git -C "$TAP" commit -m "flowlight $VERSION" >/dev/null && echo "Committed in $TAP — push it to publish."
fi
