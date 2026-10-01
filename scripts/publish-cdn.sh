#!/usr/bin/env bash
# Publishes a signed, notarized package from dist/archives to https://cdn.snapok.app (R2 bucket "snapok"),
# which the app's updater reads.
#
#   CHANNEL=dev|release ./scripts/publish-cdn.sh <package.dmg> <package.zip>
#
# Layout (release at the root, development builds under dev/):
#   latest.json  Snapok.dmg  Snapok-<version>.{dmg,zip}
#   dev/latest.json  dev/Snapok-Dev.dmg  dev/Snapok-Dev-<version>-<build>.{dmg,zip}
#
# Versioned packages go up first (cached forever), then the fixed download link, and latest.json last,
# so a client never reads a manifest whose package is missing. A release version with "-" (1.2.0-beta.1)
# uploads its packages only. A feed that already offers a newer build is left alone.
#
# Uploads go through the snapok-cdn-upload Worker (cdn/worker.js) when CDN_UPLOAD_TOKEN is set (CI),
# otherwise through the local wrangler login.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CDN=https://cdn.snapok.app
UPLOAD_URL=https://snapok-cdn-upload.me-6e5.workers.dev
BUCKET=snapok
DMG="${1:?usage: CHANNEL=dev|release $0 <package.dmg> <package.zip>}"
ZIP="${2:?usage: CHANNEL=dev|release $0 <package.dmg> <package.zip>}"
for f in "$DMG" "$ZIP"; do [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }; done

CHANNEL="${CHANNEL:-dev}"
case "$CHANNEL" in
  release) APP_NAME="Snapok"; PREFIX=""; FILE_PREFIX="Snapok" ;;
  dev) APP_NAME="Snapok Dev"; PREFIX="dev/"; FILE_PREFIX="Snapok-Dev" ;;
  *) echo "CHANNEL must be dev or release" >&2; exit 1 ;;
esac

# Version and build come from the packaged app itself.
INFO="$(mktemp -d)"
trap 'rm -rf "$INFO"' EXIT
ditto -x -k "$ZIP" "$INFO"
PLIST="$INFO/$APP_NAME.app/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo "$ZIP does not contain $APP_NAME.app" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")

if [[ "$CHANNEL" == release ]]; then STEM="$FILE_PREFIX-$VERSION"; else STEM="$FILE_PREFIX-$VERSION-$BUILD"; fi

if [[ -n "${CDN_UPLOAD_TOKEN:-}" ]]; then
  upload() { # <file> <key> <content-type> <cache-control>
    echo "==> $CDN/$2"
    curl -fsS --retry 5 --retry-all-errors -X PUT -o /dev/null \
      -H "Authorization: Bearer $CDN_UPLOAD_TOKEN" -H "Content-Type: $3" -H "X-Cache-Control: $4" \
      --data-binary "@$1" "$UPLOAD_URL/$2"
  }
else
  upload() {
    echo "==> $CDN/$2"
    npx -y wrangler@latest r2 object put "$BUCKET/$2" --file "$1" --content-type "$3" --cache-control "$4" --remote >/dev/null
  }
fi

# Never move the feed backwards (an older run finishing late, or a re-run of an old commit).
CURRENT=$(curl -fsS "$CDN/${PREFIX}latest.json?t=$(date +%s)" 2>/dev/null || true)
if [[ -n "$CURRENT" ]] && ! python3 - "$VERSION" "$BUILD" "$CURRENT" <<'PY'
import json, sys
def key(version, build):
    core, _, pre = version.partition("-")
    nums = [int(n) if n.isdigit() else 0 for n in core.split(".")] + [0, 0, 0]
    return nums[:3], pre == "", [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")], int(build or 0)
current = json.loads(sys.argv[3])
sys.exit(0 if key(sys.argv[1], sys.argv[2]) > key(current["version"], str(current.get("build", 0))) else 1)
PY
then
  echo "Feed already offers a build at least as new as $VERSION ($BUILD); nothing published."
  exit 0
fi

IMMUTABLE="public, max-age=31536000, immutable"
upload "$ZIP" "$PREFIX$STEM.zip" application/zip "$IMMUTABLE"
upload "$DMG" "$PREFIX$STEM.dmg" application/x-apple-diskimage "$IMMUTABLE"

if [[ "$CHANNEL" == release && "$VERSION" == *-* ]]; then
  echo "Prerelease $VERSION uploaded; latest.json unchanged."
  exit 0
fi

upload "$DMG" "$PREFIX$FILE_PREFIX.dmg" application/x-apple-diskimage "public, max-age=300"

MANIFEST="$INFO/latest.json"
VERSION="$VERSION" BUILD="$BUILD" MIN_OS="$MIN_OS" CDN="$CDN" STEM="$PREFIX$STEM" NOTES="${NOTES:-}" \
SHA256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1) SIZE=$(stat -f %z "$ZIP") \
python3 - > "$MANIFEST" <<'PY'
import datetime, json, os
e, cdn, stem = os.environ, os.environ["CDN"], os.environ["STEM"]
print(json.dumps({
    "version": e["VERSION"],
    "build": int(e["BUILD"]),
    "notes": e["NOTES"].strip(),
    "url": f"{cdn}/{stem}.zip",
    "sha256": e["SHA256"],
    "size": int(e["SIZE"]),
    "dmg": f"{cdn}/{stem}.dmg",
    "minimumSystemVersion": e["MIN_OS"],
    "page": "https://snapok.app",
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, ensure_ascii=False, indent=2))
PY
upload "$MANIFEST" "${PREFIX}latest.json" "application/json; charset=utf-8" "no-store, max-age=0"
echo "Published $APP_NAME $VERSION ($BUILD) → $CDN/${PREFIX}latest.json"
