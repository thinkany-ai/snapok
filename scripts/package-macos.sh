#!/usr/bin/env bash
# Universal DMG + ZIP; --signed enables Developer ID signing and Apple notarization.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:---unsigned}"
[[ "$MODE" == --unsigned || "$MODE" == --signed ]] || { echo "Use --unsigned or --signed" >&2; exit 1; }
if [[ "$MODE" == --signed ]]; then
  for name in APPLE_SIGNING_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
    [[ -n "${!name:-}" ]] || { echo "Missing $name" >&2; exit 1; }
  done
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
SUFFIX="${PACKAGE_SUFFIX:-dev}"
[[ "$SUFFIX" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "Invalid PACKAGE_SUFFIX" >&2; exit 1; }
APP="$ROOT_DIR/dist/SnapAny.app"
ARCHIVES="$ROOT_DIR/dist/archives"
NAME="SnapAny-$VERSION-$SUFFIX-universal"
[[ "$MODE" == --signed ]] || NAME="$NAME-unsigned"
mkdir -p "$ARCHIVES"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

notarize() {
  local result="$STAGING/notary-result.json"
  xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait --output-format json > "$result"
  python3 - "$result" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
if r.get('status') != 'Accepted':
    raise SystemExit('Notarization failed: status=%s, submission=%s' % (r.get('status'), r.get('id')))
print('Notarization accepted: ' + r['id'])
PY
}

SIGN_IDENTITY=- ./scripts/build-app.sh release --universal
if [[ "$MODE" == --signed ]]; then
  codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  ditto -c -k --keepParent "$APP" "$STAGING/notarize.zip"
  notarize "$STAGING/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

ditto -c -k --keepParent "$APP" "$ARCHIVES/$NAME.zip"
mkdir "$STAGING/dmg"
ditto "$APP" "$STAGING/dmg/SnapAny.app"
ln -s /Applications "$STAGING/dmg/Applications"
hdiutil create -volname SnapAny -srcfolder "$STAGING/dmg" -ov -format UDZO "$ARCHIVES/$NAME.dmg"
if [[ "$MODE" == --signed ]]; then
  codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$ARCHIVES/$NAME.dmg"
  notarize "$ARCHIVES/$NAME.dmg"
  xcrun stapler staple "$ARCHIVES/$NAME.dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$ARCHIVES/$NAME.dmg"
fi
(cd "$ARCHIVES" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > "$NAME-SHA256SUMS.txt")
echo "Packages: $ARCHIVES/$NAME.{dmg,zip}"
