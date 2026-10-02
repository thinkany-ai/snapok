#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 "$ROOT_DIR/Sources/Snapok/BackgroundRenderer.swift" \
  "$ROOT_DIR/Sources/Snapok/BackgroundPreferences.swift" \
  "$ROOT_DIR/Tests/SnapokTests/BackgroundRendererTests.swift" -o "$TEST_DIR/background-tests"
"$TEST_DIR/background-tests" "$@"
