#!/usr/bin/env bash
# ./scripts/dev.sh — build and launch "Snapok Dev", then rebuild and relaunch whenever sources change.
# Uses fswatch when installed (brew install fswatch); otherwise polls once per second.
# A failed build leaves the running app untouched. Press Ctrl+C to stop watching and quit the app.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Snapok Dev.app"
APP_BIN="$APP_DIR/Contents/MacOS/Snapok"
LOG_FILE="$HOME/Library/Logs/Snapok Dev.log"
WATCH_PATHS=(Sources Resources Package.swift)
cd "$ROOT_DIR"

STAMP="$(mktemp)"
TAIL_PID=""

quit_app() {
  pkill -f "$APP_BIN" 2>/dev/null || return 0
  for _ in {1..50}; do pgrep -f "$APP_BIN" >/dev/null || return 0; sleep 0.1; done
  pkill -9 -f "$APP_BIN" 2>/dev/null || true
}

cleanup() {
  [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null
  quit_app
  rm -f "$STAMP"
  exit 0
}
trap cleanup INT TERM

build_and_launch() {
  touch "$STAMP"
  echo "==> Building Snapok Dev ($(date +%H:%M:%S))"
  if ! ./scripts/build-app.sh debug; then
    echo "==> Build failed; keeping the previous app running. Waiting for changes…"
    return
  fi
  quit_app
  # Launch through LaunchServices so macOS attributes privacy permissions to the app, not the terminal.
  open "$APP_DIR"
  echo "==> Launched. Watching ${WATCH_PATHS[*]} (Ctrl+C to stop)"
}

wait_for_change() {
  if command -v fswatch >/dev/null; then
    fswatch -1 -r -l 0.3 "${WATCH_PATHS[@]}" >/dev/null
  else
    until [[ -n "$(find "${WATCH_PATHS[@]}" -type f -newer "$STAMP" -print -quit 2>/dev/null)" ]]; do
      sleep 1
    done
  fi
  sleep 0.3 # let editors finish writing related files
}

touch "$LOG_FILE"
tail -n 0 -F "$LOG_FILE" &
TAIL_PID=$!

build_and_launch
while true; do
  wait_for_change
  build_and_launch
done
