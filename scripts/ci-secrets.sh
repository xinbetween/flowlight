#!/bin/zsh
# Puts everything .github/workflows/release.yml needs into GitHub Actions secrets.
#
#   scripts/ci-secrets.sh
#
# It reads the two .p12 certificate exports, the two provisioning profiles and the App Store Connect key you point
# it at, and uploads each with `gh secret set`. File contents are piped straight to gh and never printed.
#
# They go into the `release` environment, not the repository, so only the release job can read them and only after
# a human approves the run. Even so: anyone who can approve a release can sign software as you, and anyone with
# admin access can change who that is. Revoke the identities in Apple's developer portal if that stops being true.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-xinbetween/flowlight}"
ENVIRONMENT="${ENVIRONMENT:-release}"
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login" >&2; exit 1; }

ask() { printf '%s' "$1" >&2; read -r REPLY; print -r -- "$REPLY"; }

echo "Setting Actions secrets on $REPO, in the $ENVIRONMENT environment."
gh api "repos/$REPO/environments/$ENVIRONMENT" >/dev/null 2>&1 || {
  echo "No $ENVIRONMENT environment on $REPO. Create it first (Settings › Environments), with a required reviewer" >&2
  echo "and a deployment branch policy limited to the tag pattern v*." >&2
  exit 1
}
echo

APP_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
INSTALLER_ID=$(security find-identity -v | grep "Developer ID Installer" | head -1 | sed 's/.*"\(.*\)"/\1/')
[[ -n "$APP_ID" ]] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }
[[ -n "$INSTALLER_ID" ]] || { echo "No Developer ID Installer identity in the keychain." >&2; exit 1; }
TEAM_ID=$(print -r -- "$APP_ID" | sed 's/.*(\(.*\))/\1/')
echo "Signing identity: $APP_ID"
echo "Installer identity: $INSTALLER_ID"
echo "Team: $TEAM_ID"
echo

# Keychain Access is the only reliable way to get one identity out: `security export` takes every identity at
# once and can't be told which, and exporting the lot would put more key material in CI than the release needs.
echo "Export both certificates from Keychain Access, giving them the same password:"
echo "  1. Open Keychain Access and click the My Certificates tab — not All Items. Export is only offered there,"
echo "     because only that view pairs a certificate with its private key."
echo "  2. Select \"Developer ID Application: …\", then File › Export Items… and save a .p12."
echo "  3. Do the same for \"Developer ID Installer: …\"."
APP_P12=$(ask "  Path to the Developer ID Application .p12: ")
INSTALLER_P12=$(ask "  Path to the Developer ID Installer .p12: ")
printf '  Password you gave them: ' >&2
read -rs P12_PASSWORD; echo >&2
for path in "$APP_P12" "$INSTALLER_P12"; do
  expanded="${path/#\~/$HOME}"
  [[ -s "$expanded" ]] || { echo "No file at $expanded" >&2; exit 1; }
done
# Check the password here rather than in CI, where a bad one reads as "The specified item could not be found in
# the keychain". The check is the same `security import` the release job does, into a keychain thrown away after.
# The password goes through the environment, never an argument: a `pass:` argument is fragile with $ and \ in it.
check_password() {
  local probe="${TMPDIR:-/tmp}/flowlight-probe-$$.keychain-db" probe_password
  probe_password=$(uuidgen)
  security create-keychain -p "$probe_password" "$probe" 2>/dev/null || return 2
  security unlock-keychain -p "$probe_password" "$probe" 2>/dev/null
  local path result=0 message
  for path in "$@"; do
    message=$(security import "${path/#\~/$HOME}" -k "$probe" -P "$P12_PASSWORD" -T /usr/bin/codesign 2>&1) || {
      echo "  $path: $message" >&2
      result=1
    }
  done
  security delete-keychain "$probe" 2>/dev/null
  return $result
}

if ! check_password "$APP_P12" "$INSTALLER_P12"; then
  echo >&2
  echo "That password didn't open one of them. If you're sure it's right, this check may simply be wrong about" >&2
  echo "your files — the upload itself doesn't depend on it." >&2
  CONTINUE=$(ask "  Upload anyway? [y/N]: ")
  [[ "$CONTINUE" == [yY]* ]] || exit 1
fi
echo

# Xcode leaves the downloaded profiles under opaque UUID names, so they're matched on the name stored inside.
# `find` rather than a glob: a glob qualifier depends on shell options this script doesn't control.
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
find_profile() {
  local wanted="$1" f name
  [[ -d "$PROFILE_DIR" ]] || return 1
  while IFS= read -r f; do
    name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null) || continue
    if [[ "$name" == "$wanted" ]]; then
      print -r -- "$f"
      return 0
    fi
  done < <(find "$PROFILE_DIR" -maxdepth 1 -name '*.provisionprofile' -print 2>/dev/null)
  return 1
}

# What's actually there, so a miss below is explainable rather than mysterious.
list_profiles() {
  local f name
  [[ -d "$PROFILE_DIR" ]] || { echo "  (no $PROFILE_DIR)"; return; }
  while IFS= read -r f; do
    name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null) || name="(unreadable)"
    echo "  $name"
  done < <(find "$PROFILE_DIR" -maxdepth 1 -name '*.provisionprofile' -print 2>/dev/null)
}

APP_PROFILE_PATH=$(find_profile "${APP_PROFILE_NAME:-Flowlight Developer ID}" || true)
EXT_PROFILE_PATH=$(find_profile "${EXT_PROFILE_NAME:-Flowlight Extension Developer ID}" || true)
if [[ -z "$APP_PROFILE_PATH" || -z "$EXT_PROFILE_PATH" ]]; then
  echo "Provisioning profiles Xcode has downloaded:"
  list_profiles
  echo "Looking for \"${APP_PROFILE_NAME:-Flowlight Developer ID}\" and \"${EXT_PROFILE_NAME:-Flowlight Extension Developer ID}\"."
  echo "Missing one? Download it from developer.apple.com, or open Xcode › Settings › Accounts › Download Manual Profiles."
fi
if [[ -n "$APP_PROFILE_PATH" ]]; then
  echo "Found \"${APP_PROFILE_NAME:-Flowlight Developer ID}\" at $(basename "$APP_PROFILE_PATH")"
else
  APP_PROFILE_PATH=$(ask "Path to the app's .provisionprofile: ")
fi
if [[ -n "$EXT_PROFILE_PATH" ]]; then
  echo "Found \"${EXT_PROFILE_NAME:-Flowlight Extension Developer ID}\" at $(basename "$EXT_PROFILE_PATH")"
else
  EXT_PROFILE_PATH=$(ask "Path to the extension's .provisionprofile: ")
fi
for path in "$APP_PROFILE_PATH" "$EXT_PROFILE_PATH"; do
  expanded="${path/#\~/$HOME}"
  [[ -s "$expanded" ]] || { echo "No file at $expanded" >&2; exit 1; }
done
echo

# notarytool takes either. The App Store Connect key is narrower — it can only notarize, and revoking it affects
# nothing else — but it has to be created first. An app-specific password reuses what you already notarize with.
echo "How should CI notarize?"
echo "  1) App Store Connect API key (recommended: only notarizes, revoke it freely)"
echo "  2) Apple ID + app-specific password (what you already use locally)"
NOTARY_CHOICE=$(ask "  Choose 1 or 2: ")
NOTARY_KEY_PATH="" NOTARY_KEY_ID="" NOTARY_ISSUER="" NOTARY_APPLE_ID="" NOTARY_PASSWORD=""
if [[ "$NOTARY_CHOICE" == "2" ]]; then
  NOTARY_APPLE_ID=$(ask "  Apple ID: ")
  printf '  App-specific password (appleid.apple.com › Sign-In and Security): ' >&2
  read -rs NOTARY_PASSWORD; echo >&2
  [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_PASSWORD" ]] || { echo "Both are needed." >&2; exit 1; }
else
  echo "  Create one at appstoreconnect.apple.com › Users and Access › Integrations › App Store Connect API."
  echo "  A Developer-role team key is enough. The .p8 downloads once and cannot be downloaded again."
  NOTARY_KEY_PATH=$(ask "  Path to AuthKey_*.p8: ")
  NOTARY_KEY_ID=$(ask "  Key ID: ")
  NOTARY_ISSUER=$(ask "  Issuer ID: ")
  expanded="${NOTARY_KEY_PATH/#\~/$HOME}"
  [[ -s "$expanded" ]] || { echo "No file at $expanded" >&2; exit 1; }
  [[ -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]] || { echo "Key ID and Issuer ID are both needed." >&2; exit 1; }
fi

set_secret() { gh secret set "$1" --repo "$REPO" --env "$ENVIRONMENT" --body "$2" >/dev/null && echo "  set $1"; }
set_file()   { base64 < "${2/#\~/$HOME}" | tr -d '\n' | gh secret set "$1" --repo "$REPO" --env "$ENVIRONMENT" >/dev/null && echo "  set $1"; }

echo
echo "Uploading:"
set_file   APP_CERTIFICATE_P12       "$APP_P12"
set_file   INSTALLER_CERTIFICATE_P12 "$INSTALLER_P12"
set_secret CERTIFICATE_PASSWORD      "$P12_PASSWORD"
set_file   APP_PROVISIONING_PROFILE  "$APP_PROFILE_PATH"
set_file   EXT_PROVISIONING_PROFILE  "$EXT_PROFILE_PATH"
if [[ -n "$NOTARY_KEY_PATH" ]]; then
  set_file   NOTARY_KEY_P8           "$NOTARY_KEY_PATH"
  set_secret NOTARY_KEY_ID           "$NOTARY_KEY_ID"
  set_secret NOTARY_ISSUER           "$NOTARY_ISSUER"
else
  set_secret NOTARY_APPLE_ID         "$NOTARY_APPLE_ID"
  set_secret NOTARY_PASSWORD         "$NOTARY_PASSWORD"
  set_secret NOTARY_TEAM_ID          "$TEAM_ID"
fi
set_secret TEAM_ID                   "$TEAM_ID"
set_secret DMG_SIGN_IDENTITY         "$APP_ID"
set_secret INSTALLER_IDENTITY        "$INSTALLER_ID"

echo
echo "TAP_TOKEN is optional: a fine-grained token with Contents: write on xinbetween/homebrew-tap, which lets the"
echo "release job update the Homebrew cask. Add it to the same environment; without it that step is skipped and"
echo "you run scripts/update-cask.sh yourself."
echo
echo "Try it against a tag that already exists: gh workflow run Release --repo $REPO --ref v0.2.2"
echo "It will wait for your approval before it touches any of this."
