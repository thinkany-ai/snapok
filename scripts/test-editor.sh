#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Compile the app classes without its entry point; the test owns the AppKit application.
sed '/^@main$/d' "$ROOT_DIR/Sources/SnapAny/SnapAnyApp.swift" > "$TEST_DIR/AppSource.swift"
swiftc -swift-version 6 -target "$(uname -m)-apple-macos14.0" -parse-as-library \
  "$ROOT_DIR/Sources/SnapAny/FocusDetector.swift" "$ROOT_DIR/Sources/SnapAny/BackgroundRenderer.swift" \
  "$ROOT_DIR/Sources/SnapAny/EditorCanvas.swift" "$ROOT_DIR/Sources/SnapAny/BackgroundEditor.swift" \
  "$TEST_DIR/AppSource.swift" "$ROOT_DIR/Tests/SnapAnyTests/EditorCanvasTests.swift" -o "$TEST_DIR/editor-tests"
"$TEST_DIR/editor-tests" "$@"
