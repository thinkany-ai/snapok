#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Compile the app classes without its entry point; the test owns the AppKit application.
sed '/^@main$/d' "$ROOT_DIR/Sources/Snapok/SnapokApp.swift" > "$TEST_DIR/AppSource.swift"
SOURCES=()
for file in "$ROOT_DIR"/Sources/Snapok/*.swift; do
  [[ "$(basename "$file")" == SnapokApp.swift ]] || SOURCES+=("$file")
done
swiftc -swift-version 6 -target "$(uname -m)-apple-macos14.0" -parse-as-library \
  "${SOURCES[@]}" "$TEST_DIR/AppSource.swift" "$ROOT_DIR/Tests/SnapokTests/HotKeyTests.swift" -o "$TEST_DIR/hotkey-tests"
"$TEST_DIR/hotkey-tests"
