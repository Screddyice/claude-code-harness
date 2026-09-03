#!/usr/bin/env bash
# Exercises cognee-remember-durable against a fake Cognee that "lands" a write
# only after a chosen number of data listings, and a fake remember script that
# records every send. No network, no real Cognee.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'kill "${SERVER_PID:-0}" 2>/dev/null; wait "${SERVER_PID:-0}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

cat > "$TMP/fake_cognee.py" <<'PY'
import hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
LAND_AFTER = int(sys.argv[2]); STATE = {"lists": 0}
MD5 = hashlib.md5(os.environ["EXPECT_CONTENT"].encode()).hexdigest()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/api/v1/datasets":
            body = [{"id": "ds-1", "name": "agent_sessions"}]
        elif self.path == "/api/v1/datasets/ds-1/data":
            STATE["lists"] += 1
            body = [{"id": "x", "rawDataLocation": f"file:///d/text_{MD5}.txt"}] if STATE["lists"] >= LAND_AFTER else []
        else:
            self.send_response(404); self.end_headers(); return
        raw = json.dumps(body).encode(); self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(raw)
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
cat > "$TMP/fake_remember.sh" <<'SH2'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SENDS"; echo '{"ok": true, "status": "running"}'
SH2
chmod +x "$TMP/fake_remember.sh"
CONTENT="durable-test-fact $(date +%s%N)"
export EXPECT_CONTENT="$CONTENT" SENDS="$TMP/sends" COGNEE_BASE_URL="http://127.0.0.1:$PORT" COGNEE_API_KEY=t \
  COGNEE_PLUGIN_DATASET=agent_sessions COGNEE_OUTBOX="$TMP/outbox" COGNEE_REMEMBER_BIN="$TMP/fake_remember.sh" \
  COGNEE_DURABLE_WAIT=4 COGNEE_DURABLE_POLL=1 COGNEE_DURABLE_RESEND=0

fail() { echo "FAIL: $*" >&2; exit 1; }

# Case 1: lands on the second listing -> stored:true, outbox empty, exactly one send.
python3 "$TMP/fake_cognee.py" "$PORT" 2 & SERVER_PID=$!; sleep 0.5
out=$("$HERE/cognee-remember-durable.sh" "$CONTENT" --node-set project_docs)
echo "$out" | grep -q '"stored": true' || fail "case1 expected stored:true, got: $out"
[ -z "$(ls -A "$TMP/outbox" 2>/dev/null | grep -v drain)" ] || fail "case1 outbox not empty"
[ "$(wc -l < "$SENDS")" -eq 1 ] || fail "case1 expected one send"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null || true; : > "$SENDS"; rm -rf "$TMP/outbox"

# Case 2: never lands inside the wait -> queued:true, journal kept, drainer spawned; a later
# --drain --once pass re-sends (RESEND=0) and clears the entry once the listing shows it.
python3 "$TMP/fake_cognee.py" "$PORT" 4 & SERVER_PID=$!; sleep 0.5
out=$(COGNEE_DURABLE_WAIT=1 "$HERE/cognee-remember-durable.sh" "$CONTENT" --node-set user_context)
echo "$out" | grep -q '"queued": true' || fail "case2 expected queued:true, got: $out"
ls "$TMP/outbox"/*.json >/dev/null 2>&1 || fail "case2 journal missing"
sleep 3   # the detached drainer polls every 1s; listings 2,3 miss, 4 lands
[ -z "$(ls "$TMP/outbox"/*.json 2>/dev/null)" ] || fail "case2 drainer did not clear the entry: $(cat "$TMP/outbox"/*.json)"
[ "$(wc -l < "$SENDS")" -ge 2 ] || fail "case2 expected a re-send, sends=$(wc -l < "$SENDS")"
echo "ok: cognee-remember-durable stores, queues, re-sends, and clears"
