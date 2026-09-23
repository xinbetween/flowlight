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
# once and can't be told which. In Keychain Access, right-click each certificate › Export… and save a .p12.
echo "Export both certificates from Keychain Access (right-click › Export…, format .p12, same password for both)."
APP_P12=$(ask "  Path to the Developer ID Application .p12: ")
INSTALLER_P12=$(ask "  Path to the Developer ID Installer .p12: ")
printf '  Password you gave them: ' >&2
read -rs P12_PASSWORD; echo >&2
for path in "$APP_P12" "$INSTALLER_P12"; do
  expanded="${path/#\~/$HOME}"
  [[ -s "$expanded" ]] || { echo "No file at $expanded" >&2; exit 1; }
done
# Fail here rather than in CI, where the error is "The specified item could not be found in the keychain".
for path in "$APP_P12" "$INSTALLER_P12"; do
  openssl pkcs12 -in "${path/#\~/$HOME}" -passin "pass:$P12_PASSWORD" -nokeys -noout 2>/dev/null \
    || { echo "That password doesn't open ${path}." >&2; exit 1; }
done
echo

APP_PROFILE_PATH=$(ask "Path to the app's .provisionprofile: ")
EXT_PROFILE_PATH=$(ask "Path to the extension's .provisionprofile: ")
NOTARY_KEY_PATH=$(ask "Path to the App Store Connect API key (AuthKey_*.p8): ")
NOTARY_KEY_ID=$(ask "Its Key ID: ")
NOTARY_ISSUER=$(ask "Its Issuer ID: ")
for path in "$APP_PROFILE_PATH" "$EXT_PROFILE_PATH" "$NOTARY_KEY_PATH"; do
  expanded="${path/#\~/$HOME}"
  [[ -s "$expanded" ]] || { echo "No file at $expanded" >&2; exit 1; }
done

set_secret() { gh secret set "$1" --repo "$REPO" --env "$ENVIRONMENT" --body "$2" >/dev/null && echo "  set $1"; }
set_file()   { base64 < "${2/#\~/$HOME}" | tr -d '\n' | gh secret set "$1" --repo "$REPO" --env "$ENVIRONMENT" >/dev/null && echo "  set $1"; }

echo
echo "Uploading:"
set_file   APP_CERTIFICATE_P12       "$APP_P12"
set_file   INSTALLER_CERTIFICATE_P12 "$INSTALLER_P12"
set_secret CERTIFICATE_PASSWORD      "$P12_PASSWORD"
set_file   APP_PROVISIONING_PROFILE  "$APP_PROFILE_PATH"
set_file   EXT_PROVISIONING_PROFILE  "$EXT_PROFILE_PATH"
set_file   NOTARY_KEY_P8             "$NOTARY_KEY_PATH"
set_secret NOTARY_KEY_ID             "$NOTARY_KEY_ID"
set_secret NOTARY_ISSUER             "$NOTARY_ISSUER"
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
