#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -O "$ROOT_DIR/Sources/Snapok/ScrollStitcher.swift" \
  "$ROOT_DIR/Tests/SnapokTests/ScrollStitcherTests.swift" -o "$TEST_DIR/scroll-tests"
"$TEST_DIR/scroll-tests"
