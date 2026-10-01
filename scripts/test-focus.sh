#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 "$ROOT_DIR/Sources/Snapok/FocusDetector.swift" \
  "$ROOT_DIR/Tests/SnapokTests/FocusGeometryTests.swift" -o "$TEST_DIR/focus-tests"
"$TEST_DIR/focus-tests" "$@"
