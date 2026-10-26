#!/bin/zsh
# Submits one file to Apple's notary service and staples the ticket to it.
#
#   NOTARY_PROFILE=flowlight-notary scripts/notarize.sh build/Flowlight.dmg
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER=<uuid> scripts/notarize.sh build/Flowlight.dmg
#   NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=ABCDE12345 NOTARY_PASSWORD=<app-specific> scripts/notarize.sh …
#
# A keychain profile is the convenient way on your own Mac. CI has no keychain of yours to read, so it passes
# credentials directly: an App Store Connect key if you have one — it only notarizes, and revoking it costs
# nothing — or an Apple ID with an app-specific password. With none of the three set this exits quietly, so
# unsigned local builds still work.
#
# A .app can't be uploaded as-is: it goes up inside a zip, and the ticket is stapled to the bundle afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?Usage: scripts/notarize.sh <file>}"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
  CREDENTIALS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  CREDENTIALS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
else
  echo "Notarization skipped: set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER," >&2
  echo "or NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD." >&2
  exit 0
fi

CLEANUP=$(mktemp -d "${TMPDIR:-/tmp}/flowlight-notarize.XXXXXX")
cleanup() {
  rm -rf -- "$CLEANUP"
}
trap cleanup EXIT

UPLOAD="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  UPLOAD="$CLEANUP/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$UPLOAD"
fi

xcrun notarytool submit "$UPLOAD" "${CREDENTIALS[@]}" --wait

# Apple's stapler occasionally loses its CloudKit connection after the notary service has already accepted the
# upload (NSURLErrorDomain -1005). Re-submitting would create a second notarization request, so retry only the
# idempotent staple operation, only for that known transport failure, and with a short bounded backoff.
staple_attempt=1
staple_delay=2
staple_max_attempts=4
while true; do
  staple_log="$CLEANUP/stapler-$staple_attempt.log"
  set +e
  xcrun stapler staple "$TARGET" 2>&1 | tee "$staple_log"
  staple_status=${pipestatus[1]}
  set -e
  if (( staple_status == 0 )); then
    break
  fi

  if ! grep -Eq 'NSURLErrorDomain( |:|,).*Code=-1005([^0-9]|$)' "$staple_log"; then
    exit "$staple_status"
  fi
  if (( staple_attempt >= staple_max_attempts )); then
    print -u2 -- "Stapling failed after $staple_attempt attempts: transient Apple connection loss did not recover."
    exit "$staple_status"
  fi

  print -u2 -- "Stapling hit transient Apple connection loss; retrying in ${staple_delay}s ($staple_attempt/$staple_max_attempts)."
  sleep "$staple_delay"
  (( staple_attempt += 1 ))
  (( staple_delay *= 2 ))
done

echo "Notarized and stapled: $TARGET"
