#!/bin/bash
# Notarize and staple the latest clawome DMG build.
# Usage: ./notarize_and_staple.sh --apple-id <id> --password <app-specific-password>
#   or:  ./notarize_and_staple.sh <apple-id> <app-specific-password>
#   or:  APPLE_ID=... APP_PASSWORD=... ./notarize_and_staple.sh
#
# --submission-id: skip submit and wait for that submission, then staple.
# App-specific password: https://appleid.apple.com → Sign-In and Security → App-Specific Passwords
set -e
cd "$(dirname "$0")"

TEAM_ID="F44ZS9HT2P"

APPLE_ID="${APPLE_ID}"
APP_PASSWORD="${APP_PASSWORD}"
SUBMISSION_ID="${SUBMISSION_ID}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apple-id)
      APPLE_ID="$2"
      shift 2
      ;;
    --password)
      APP_PASSWORD="$2"
      shift 2
      ;;
    --submission-id)
      SUBMISSION_ID="$2"
      shift 2
      ;;
    *)
      if [ -z "$APPLE_ID" ]; then
        APPLE_ID="$1"
      elif [ -z "$APP_PASSWORD" ]; then
        APP_PASSWORD="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$APPLE_ID" ] || [ -z "$APP_PASSWORD" ]; then
  echo "Usage: $0 [--apple-id <id>] [--password <app-specific-password>] [--submission-id <id>]"
  echo "   or: $0 <apple-id> <app-specific-password> [--submission-id <id>]"
  echo "   or: APPLE_ID=... APP_PASSWORD=... $0 [--submission-id <id>]"
  echo ""
  echo "  --apple-id <id>       Developer Apple ID."
  echo "  --password <password> App-specific password."
  echo "  --submission-id <id>  Skip submit and wait for that submission, then staple."
  echo ""
  echo "Create an app-specific password at https://appleid.apple.com"
  exit 1
fi

RELEASE_DIR="release"
DMG=$(find "$RELEASE_DIR" -name "*.dmg" -type f 2>/dev/null | while IFS= read -r f; do printf "%s\t%s\n" "$(stat -f "%m" "$f" 2>/dev/null)" "$f"; done | sort -rn | head -1 | cut -f2-)

if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
  echo "[notarize] No DMG found in $RELEASE_DIR. Run ./build.sh first."
  exit 1
fi

if [ -n "$SUBMISSION_ID" ]; then
  echo "[notarize] Waiting for submission $SUBMISSION_ID..."
  xcrun notarytool wait "$SUBMISSION_ID" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID"
else
  echo "[notarize] Submitting $DMG for notarization..."
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait
fi

echo "[notarize] Notarization succeeded. Stapling..."
xcrun stapler staple "$DMG"

echo "[notarize] Done. Notarized and stapled: $DMG"
