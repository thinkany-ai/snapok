#!/usr/bin/env bash
# ./scripts/build-app.sh [release|debug] [--universal]
# CHANNEL=dev (default) builds "Snapok Dev" (ai.thinkany.snapok.dev); CHANNEL=release builds "Snapok" (ai.thinkany.snapok).
# The two channels install side by side with separate data, settings, Keychain items, and hotkeys.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
MODE="${2:-}"
CHANNEL="${CHANNEL:-dev}"
[[ "$CONFIGURATION" == release || "$CONFIGURATION" == debug ]] || { echo "Expected release or debug" >&2; exit 1; }
[[ -z "$MODE" || "$MODE" == --universal ]] || { echo "Expected --universal" >&2; exit 1; }
case "$CHANNEL" in
  release) APP_NAME="Snapok"; BUNDLE_ID="ai.thinkany.snapok"; ICON="SnapokFamily" ;;
  dev) APP_NAME="Snapok Dev"; BUNDLE_ID="ai.thinkany.snapok.dev"; ICON="SnapokFamily-Dev" ;;
  *) echo "CHANNEL must be dev or release" >&2; exit 1 ;;
esac
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
cd "$ROOT_DIR"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
if [[ "$MODE" == --universal ]]; then
  for arch in arm64 x86_64; do
    swift build -c "$CONFIGURATION" --arch "$arch"
    BIN_DIR="$(swift build -c "$CONFIGURATION" --arch "$arch" --show-bin-path)"
    cp "$BIN_DIR/Snapok" "$STAGING/Snapok-$arch"
  done
  lipo -create "$STAGING/Snapok-arm64" "$STAGING/Snapok-x86_64" -output "$STAGING/Snapok"
else
  swift build -c "$CONFIGURATION"
  BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
  cp "$BIN_DIR/Snapok" "$STAGING/Snapok"
fi
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$STAGING/Snapok" "$APP_DIR/Contents/MacOS/Snapok"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp "Resources/Brand/$ICON.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Sources/Snapok/Resources/*.png "$APP_DIR/Contents/Resources/"
cp "Resources/Brand/$ICON.png" "$APP_DIR/Contents/Resources/AppIcon.png"
PLIST="$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName $APP_NAME" \
  -c "Set :CFBundleDisplayName $APP_NAME" -c "Set :SnapokChannel $CHANNEL" "$PLIST"
cp -R "$BIN_DIR/Snapok_Snapok.bundle" "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/MacOS/Snapok"
# Telemetry keys exist only in the project's own CI builds; builds from source leave them out and never report.
for pair in "SnapokPostHogKey:${POSTHOG_PROJECT_KEY:-}" "SnapokPostHogHost:${POSTHOG_HOST:-}" "SnapokSentryDSN:${SENTRY_DSN:-}"; do
  [[ -n "${pair#*:}" ]] && /usr/libexec/PlistBuddy -c "Add :${pair%%:*} string ${pair#*:}" "$PLIST"
done
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be numeric" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
fi
# Keep the local identity stable to preserve privacy grants. CI explicitly requests ad-hoc signing.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built $APP_DIR ($CHANNEL, $BUNDLE_ID, $(lipo -archs "$APP_DIR/Contents/MacOS/Snapok"))"
