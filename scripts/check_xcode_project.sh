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
working_source="$temporary/working-source"
index_source="$temporary/index-source"
index_committed="$temporary/index-committed"
mkdir -p -- "$working_source" "$index_source" "$index_committed"

copy_parent() {
  local root=$1 file=$2 parent
  if [[ "$file" == */* ]]; then parent=${file%/*}; else parent=.; fi
  mkdir -p -- "$root/$parent"
}

# Reproduce the working tree, including nonignored untracked files, without build output or Xcode state.
while IFS= read -r -d '' file; do
  case "$file" in
    Flowlight.xcodeproj/*) continue ;;
  esac
  [[ -e "$file" || -L "$file" ]] || continue
  copy_parent "$working_source" "$file"
  cp -P -- "./$file" "$working_source/$file"
done < <(git ls-files --cached --others --exclude-standard -z)

# Reproduce the exact staged tree separately. Preserve its project for comparison, then regenerate from its spec.
git checkout-index --all --prefix="$index_source/"
if [[ -d "$index_source/Flowlight.xcodeproj" ]]; then
  cp -R "$index_source/Flowlight.xcodeproj/." "$index_committed/"
  rm -rf "$index_source/Flowlight.xcodeproj"
fi

for root in "$working_source" "$index_source"; do
  (
    cd "$root"
    xcodegen generate >/dev/null
    python3 -I scripts/normalize_xcode_project.py
  )
done

copy_shared() {
  local source=$1 destination=$2 file relative parent
  mkdir -p -- "$destination"
  for file in \
    "$source/project.pbxproj" \
    "$source/project.xcworkspace/contents.xcworkspacedata"; do
    [[ -f "$file" ]] || continue
    relative=${file#"$source/"}
    copy_parent "$destination" "$relative"
    cp -- "$file" "$destination/$relative"
  done
  if [[ -d "$source/xcshareddata/xcschemes" ]]; then
    while IFS= read -r -d '' file; do
      relative=${file#"$source/"}
      copy_parent "$destination" "$relative"
      cp -- "$file" "$destination/$relative"
    done < <(find "$source/xcshareddata/xcschemes" -type f -name '*.xcscheme' -print0)
  fi
}

working_expected="$temporary/working-expected"
working_committed="$temporary/working-committed"
index_expected="$temporary/index-expected"
copy_shared "$working_source/Flowlight.xcodeproj" "$working_expected"
copy_shared Flowlight.xcodeproj "$working_committed"
copy_shared "$index_source/Flowlight.xcodeproj" "$index_expected"

if [[ "$mode" == --write ]]; then
  for file in project.pbxproj project.xcworkspace/contents.xcworkspacedata; do
    copy_parent Flowlight.xcodeproj "$file"
    cp -- "$working_expected/$file" "Flowlight.xcodeproj/$file"
  done

  mkdir -p -- Flowlight.xcodeproj/xcshareddata/xcschemes
  while IFS= read -r -d '' file; do
    relative=${file#"Flowlight.xcodeproj/"}
    [[ -f "$working_expected/$relative" ]] || rm -f -- "$file"
  done < <(find Flowlight.xcodeproj/xcshareddata/xcschemes -type f -name '*.xcscheme' -print0)
  while IFS= read -r -d '' file; do
    relative=${file#"$working_expected/"}
    copy_parent Flowlight.xcodeproj "$relative"
    cp -- "$file" "Flowlight.xcodeproj/$relative"
  done < <(find "$working_expected/xcshareddata/xcschemes" -type f -name '*.xcscheme' -print0)

  echo "Regenerated the committed Xcode project from project.yml."
  echo "Stage project.yml and Flowlight.xcodeproj, then run this check again."
  exit 0
fi

changed=0
if ! diff -qr "$working_committed" "$working_expected" >/dev/null; then
  echo "Working-tree Flowlight.xcodeproj differs from working-tree project.yml:"
  diff -ru "$working_committed" "$working_expected" || true
  changed=1
fi
if ! diff -qr "$index_committed" "$index_expected" >/dev/null; then
  echo "Staged Flowlight.xcodeproj differs from staged project.yml:"
  diff -ru "$index_committed" "$index_expected" || true
  changed=1
fi

if [[ "$changed" -ne 0 ]]; then
  echo "Flowlight.xcodeproj is out of date — run scripts/check_xcode_project.sh --write, stage the shared files, and check again." >&2
  exit 1
fi

echo "Committed Xcode project matches project.yml in both the working tree and Git index."
