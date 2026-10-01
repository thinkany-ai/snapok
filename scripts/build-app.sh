#!/usr/bin/env bash
# ./scripts/build-app.sh [release|debug] [--universal]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
MODE="${2:-}"
[[ "$CONFIGURATION" == release || "$CONFIGURATION" == debug ]] || { echo "Expected release or debug" >&2; exit 1; }
[[ -z "$MODE" || "$MODE" == --universal ]] || { echo "Expected --universal" >&2; exit 1; }
APP_DIR="$ROOT_DIR/dist/SnapAny.app"
cd "$ROOT_DIR"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
if [[ "$MODE" == --universal ]]; then
  for arch in arm64 x86_64; do
    swift build -c "$CONFIGURATION" --arch "$arch"
    BIN_DIR="$(swift build -c "$CONFIGURATION" --arch "$arch" --show-bin-path)"
    cp "$BIN_DIR/SnapAny" "$STAGING/SnapAny-$arch"
  done
  lipo -create "$STAGING/SnapAny-arm64" "$STAGING/SnapAny-x86_64" -output "$STAGING/SnapAny"
else
  swift build -c "$CONFIGURATION"
  BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
  cp "$BIN_DIR/SnapAny" "$STAGING/SnapAny"
fi
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$STAGING/SnapAny" "$APP_DIR/Contents/MacOS/SnapAny"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/Brand/SnapAnyFamily.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Sources/SnapAny/Resources/*.png "$APP_DIR/Contents/Resources/"
cp -R "$BIN_DIR/SnapAny_SnapAny.bundle" "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/MacOS/SnapAny"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be numeric" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
fi
# Keep the local identity stable to preserve privacy grants. CI explicitly requests ad-hoc signing.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built $APP_DIR ($(lipo -archs "$APP_DIR/Contents/MacOS/SnapAny"))"
