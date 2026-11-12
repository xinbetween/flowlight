#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/flowlight-cask-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

cask="$temporary/flowlight.rb"
dmg="$temporary/Flowlight.dmg"
tap="$temporary/tap"
cat > "$cask" <<'CASK'
cask "flowlight" do
  version "0.0.0"
  sha256 "old"
end
CASK
print -n -- 'trusted prepared dmg fixture' > "$dmg"
mkdir -p "$tap/Casks"
git -C "$tap" init -q
git -C "$tap" config user.name fixture
git -C "$tap" config user.email fixture@example.com
print -- fixture > "$tap/README"
git -C "$tap" add README
git -C "$tap" commit -qm fixture

VERSION=9.8.7 REQUIRE_LOCAL_DMG=1 CASK_PATH="$cask" DMG_PATH="$dmg" TAP="$tap" \
  "$root/scripts/update-cask.sh"
expected=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
grep -qx '  version "9.8.7"' "$tap/Casks/flowlight.rb"
grep -qx "  sha256 \"$expected\"" "$tap/Casks/flowlight.rb"
first_commit=$(git -C "$tap" rev-parse HEAD)

VERSION=9.8.7 REQUIRE_LOCAL_DMG=1 CASK_PATH="$cask" DMG_PATH="$dmg" TAP="$tap" \
  "$root/scripts/update-cask.sh"
[[ "$(git -C "$tap" rev-parse HEAD)" == "$first_commit" ]]

set +e
VERSION=9.8.7 REQUIRE_LOCAL_DMG=1 CASK_PATH="$cask" DMG_PATH="$temporary/missing.dmg" TAP="$tap" \
  "$root/scripts/update-cask.sh" > "$temporary/missing.out" 2>&1
missing_status=$?
set -e
[[ "$missing_status" != 0 ]]
grep -q 'REQUIRE_LOCAL_DMG is set' "$temporary/missing.out"

print -- 'Homebrew cask fixtures passed: portable rewrite, exact digest, idempotent rerun, and missing-local failure.'
