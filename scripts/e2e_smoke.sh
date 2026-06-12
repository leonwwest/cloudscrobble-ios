#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Swift tests"
HOME="$ROOT_DIR/.home" XDG_CACHE_HOME="$ROOT_DIR/.cache" CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang-module-cache" swift test --disable-sandbox

echo "==> Go tests"
cd "$ROOT_DIR/backend"
GOCACHE="$ROOT_DIR/.cache/go-build" go test ./...
cd "$ROOT_DIR"

echo "==> Token broker mock E2E"
cat > /tmp/mock_soundcloud_token.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import base64, json, urllib.parse

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8')
        params = urllib.parse.parse_qs(body)

        if self.path != '/oauth/token':
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'{"error":"not_found"}')
            return

        grant = params.get('grant_type', [''])[0]
        if grant == 'authorization_code':
            payload = {
                'access_token': 'mock_access_token',
                'refresh_token': 'mock_refresh_token',
                'token_type': 'bearer',
                'scope': 'non-expiring',
                'expires_in': 3600,
            }
        elif grant == 'refresh_token':
            payload = {
                'access_token': 'mock_access_token_refreshed',
                'refresh_token': 'mock_refresh_token_refreshed',
                'token_type': 'bearer',
                'scope': 'non-expiring',
                'expires_in': 3600,
            }
        elif grant == 'client_credentials':
            auth = self.headers.get('Authorization', '')
            expected = 'Basic ' + base64.b64encode(b'fake_client:fake_secret').decode('ascii')
            if auth != expected or params.get('client_id') or params.get('client_secret'):
                self.send_response(401)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'error':'invalid_client_credentials_auth'}).encode())
                return

            payload = {
                'access_token': 'mock_public_access_token',
                'token_type': 'bearer',
                'scope': 'non-expiring',
                'expires_in': 3600,
            }
        else:
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error':'unsupported_grant'}).encode())
            return

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def log_message(self, format, *args):
        pass

HTTPServer(('127.0.0.1', 19001), H).serve_forever()
PY

cleanup() {
  [[ -n "${BROKER_PID:-}" ]] && kill "$BROKER_PID" >/dev/null 2>&1 || true
  [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_http() {
  local url="$1"
  local attempts="${2:-30}"

  for _ in $(seq 1 "$attempts"); do
    if curl -sf "$url" >/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "Timed out waiting for $url" >&2
  return 1
}

python3 /tmp/mock_soundcloud_token.py >/tmp/mock_soundcloud_token.log 2>&1 &
MOCK_PID=$!

cd "$ROOT_DIR/backend"
ADDR=:8791 SOUNDCLOUD_CLIENT_ID=fake_client SOUNDCLOUD_CLIENT_SECRET=fake_secret SOUNDCLOUD_TOKEN_URL=http://127.0.0.1:19001/oauth/token ALLOWED_ORIGIN='*' go run . >/tmp/cloudscrobble_broker.log 2>&1 &
BROKER_PID=$!
cd "$ROOT_DIR"

wait_for_http http://127.0.0.1:8791/healthz 30

HEALTH="$(curl -sf http://127.0.0.1:8791/healthz)"
EXCHANGE="$(curl -sf -X POST http://127.0.0.1:8791/oauth/soundcloud/exchange -H 'Content-Type: application/json' -d '{"code":"auth_code","codeVerifier":"pkce_verifier","redirectUri":"cloudscrobble://oauth"}')"
REFRESH="$(curl -sf -X POST http://127.0.0.1:8791/oauth/soundcloud/refresh -H 'Content-Type: application/json' -d '{"refreshToken":"mock_refresh_token"}')"
CLIENT_CREDENTIALS="$(curl -sf -X POST http://127.0.0.1:8791/oauth/soundcloud/client-credentials -H 'Content-Type: application/json' -d '{}')"

echo "health: $HEALTH"
echo "exchange: $EXCHANGE"
echo "refresh: $REFRESH"
echo "client_credentials: $CLIENT_CREDENTIALS"

echo "==> Smoke tests passed"
