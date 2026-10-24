#!/bin/bash
# Regenerates the committed XcodeGen project in isolation and fails if its shared files drift.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || {
  echo "xcodegen is required (brew install xcodegen)." >&2
  exit 1
}

mode=${1:-check}
if [[ "$mode" != check && "$mode" != --write ]]; then
  echo "usage: scripts/check_xcode_project.sh [--write]" >&2
  exit 2
fi

temporary=$(mktemp -d "${TMPDIR:-/tmp}/flowlight-xcode-project.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

# Copy tracked and nonignored untracked files, including working-tree edits, without build output or Xcode state.
while IFS= read -r -d '' file; do
  case "$file" in
    Flowlight.xcodeproj/*) continue ;;
  esac
  [[ -e "$file" || -L "$file" ]] || continue
  mkdir -p "$temporary/$(dirname "$file")"
  cp -P "$file" "$temporary/$file"
done < <(git ls-files --cached --others --exclude-standard -z)

(
  cd "$temporary"
  xcodegen generate >/dev/null
  python3 -I scripts/normalize_xcode_project.py
)

shared=(
  "project.pbxproj"
  "project.xcworkspace/contents.xcworkspacedata"
  "xcshareddata/xcschemes/Flowlight.xcscheme"
  "xcshareddata/xcschemes/Flowlight App Store.xcscheme"
)

if [[ "$mode" == --write ]]; then
  for file in "${shared[@]}"; do
    mkdir -p "Flowlight.xcodeproj/$(dirname "$file")"
    cp "$temporary/Flowlight.xcodeproj/$file" "Flowlight.xcodeproj/$file"
  done
  echo "Regenerated the committed Xcode project from project.yml."
  exit 0
fi

changed=0
for file in "${shared[@]}"; do
  expected="$temporary/Flowlight.xcodeproj/$file"
  committed="Flowlight.xcodeproj/$file"
  if [[ ! -f "$committed" ]] || ! cmp -s "$expected" "$committed"; then
    echo "--- $committed"
    echo "+++ generated from project.yml"
    diff -u "$committed" "$expected" || true
    changed=1
  fi
done

if [[ "$changed" -ne 0 ]]; then
  echo "Flowlight.xcodeproj is out of date — run scripts/check_xcode_project.sh --write and commit the shared files." >&2
  exit 1
fi

echo "Committed Xcode project matches project.yml."
