#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
MOCK_PID=""
cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT
cat > "$TEST_DIR/mock.py" <<'PY'
import http.server, json, pathlib, sys
class Handler(http.server.BaseHTTPRequestHandler):
    calls = 0
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        content = body['messages'][-1]['content']
        images = [item for item in content if item['type'] == 'image_url']
        expected_vision = Handler.calls == 1
        if bool(images) != expected_vision:
            self.send_response(400); self.end_headers(); self.wfile.write(b'Unexpected image routing'); return
        prompt = next(item['text'] for item in content if item['type'] == 'text')
        blocks, _ = json.JSONDecoder().raw_decode(prompt)
        Handler.calls += 1
        translations = [{'id': item['id'], 'text': f"翻訳 {item['id']}"} for item in reversed(blocks)]
        response = {'choices': [{'message': {'content': json.dumps({'translations': translations})}}]}
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(response).encode())
    def log_message(self, *args): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
python3 "$TEST_DIR/mock.py" "$TEST_DIR/port" &
MOCK_PID=$!
sed '/^@main$/d' "$ROOT_DIR/Sources/Snapok/SnapokApp.swift" > "$TEST_DIR/AppSource.swift"
SOURCES=()
for file in "$ROOT_DIR"/Sources/Snapok/*.swift; do
  [[ "$(basename "$file")" == SnapokApp.swift ]] || SOURCES+=("$file")
done
swiftc -swift-version 6 -target "$(uname -m)-apple-macos14.0" -parse-as-library \
  "${SOURCES[@]}" "$TEST_DIR/AppSource.swift" "$ROOT_DIR/Tests/SnapokTests/ImageTranslationIntegrationTests.swift" -o "$TEST_DIR/translation-integration"
"$TEST_DIR/translation-integration" "$(cat "$TEST_DIR/port")"
