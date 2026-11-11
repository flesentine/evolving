#!/bin/bash
# Submits the signed saver and companion app to Apple's notary service and
# staples the tickets. Requires a Developer ID signature (Scripts/build.sh does
# that automatically when the identity is in the keychain) and notary
# credentials.
#
# One-time credential setup:
#   xcrun notarytool store-credentials evolving-notary \
#     --apple-id <your-apple-id> --team-id <TEAMID> \
#     --password <app-specific-password>
#
# Then:
#   NOTARY_PROFILE=evolving-notary Scripts/notarize.sh
#
# Alternatively pass NOTARY_APPLE_ID, NOTARY_PASSWORD and NOTARY_TEAM_ID.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SAVER="build/Evolving.saver"
APP="build/Evolving Companion.app"

if [[ ! -d "$SAVER" ]]; then
  echo "No build found at $SAVER — run Scripts/build.sh first." >&2
  exit 1
fi

if [[ -z "${NOTARY_PROFILE:-}" ]] && \
   [[ -z "${NOTARY_APPLE_ID:-}" || -z "${NOTARY_PASSWORD:-}" || -z "${NOTARY_TEAM_ID:-}" ]]; then
  cat >&2 <<'EOF'
No notarization credentials found.

Store a keychain profile once:

  xcrun notarytool store-credentials evolving-notary \
    --apple-id <your-apple-id> --team-id <TEAMID> \
    --password <app-specific-password>

Then run:

  NOTARY_PROFILE=evolving-notary Scripts/notarize.sh

(Or set NOTARY_APPLE_ID, NOTARY_PASSWORD and NOTARY_TEAM_ID.)
EOF
  exit 1
fi

submit() {
  local bundle="$1"
  local name
  name="$(basename "$bundle")"
  local zip="build/notarize-$name.zip"

  echo "▸ packaging $name"
  ditto -c -k --keepParent "$bundle" "$zip"

  echo "▸ submitting $name"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$zip" \
      --apple-id "$NOTARY_APPLE_ID" \
      --password "$NOTARY_PASSWORD" \
      --team-id "$NOTARY_TEAM_ID" \
      --wait
  fi

  echo "▸ stapling $name"
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
}

submit "$SAVER"
if [[ -d "$APP" ]]; then
  submit "$APP"
fi

echo
echo "Notarized and stapled:"
echo "  $SAVER"
[[ -d "$APP" ]] && echo "  $APP"
