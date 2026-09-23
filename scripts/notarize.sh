#!/bin/zsh
# Submits one file to Apple's notary service and staples the ticket to it.
#
#   NOTARY_PROFILE=flowlight-notary scripts/notarize.sh build/Flowlight.dmg
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER=<uuid> scripts/notarize.sh build/Flowlight.dmg
#
# A keychain profile is the convenient way on your own Mac; the App Store Connect key is what CI uses, since a
# runner has no keychain of yours to read. With neither set this exits quietly, so unsigned local builds still work.
#
# A .app can't be uploaded as-is: it goes up inside a zip, and the ticket is stapled to the bundle afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?Usage: scripts/notarize.sh <file>}"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
  CREDENTIALS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  echo "Notarization skipped: set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER." >&2
  exit 0
fi

UPLOAD="$TARGET"
CLEANUP=""
if [[ "$TARGET" == *.app ]]; then
  UPLOAD="${TMPDIR:-/tmp}/$(basename "$TARGET" .app)-notarize.zip"
  CLEANUP="$UPLOAD"
  rm -f "$UPLOAD"
  ditto -c -k --keepParent "$TARGET" "$UPLOAD"
fi

xcrun notarytool submit "$UPLOAD" "${CREDENTIALS[@]}" --wait
xcrun stapler staple "$TARGET"
[[ -n "$CLEANUP" ]] && rm -f "$CLEANUP"
echo "Notarized and stapled: $TARGET"
