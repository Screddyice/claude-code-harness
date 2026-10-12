#!/usr/bin/env bash
#
# test-oauth-expiry-monitor.sh — exercises every decision path of
# scripts/hooks/oauth-expiry-monitor.sh without touching the real keychain
# or the real log.
#
# The hook must be silent when the login is healthy (it runs on every
# SessionStart), must never block a session, and must speak up on exactly
# two conditions: the refresh-token expiry moving backwards, or entering
# the 3-day banner window.

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
monitor="$repo_root/scripts/hooks/oauth-expiry-monitor.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log="$tmp/oauth.log"
stamp="$tmp/.notified"
: > "$log"

now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"

# Build a credential blob whose refresh token expires $1 ms from now.
blob() {
  python3 -c "
import json, sys
now = $now_ms
print(json.dumps({'claudeAiOauth': {
    'refreshTokenExpiresAt': now + int(sys.argv[1]),
    'expiresAt': now + 28800000,
    'subscriptionType': 'max',
}}))" "$1"
}

# Run the monitor against a synthetic credential. Echoes its stdout.
run() {
  env LOG_PATH="$log" NOTIFY_STAMP="$stamp" \
      OAUTH_MONITOR_TEST_JSON="$1" \
      MONITOR_NO_NOTIFY=1 \
      "$monitor" ${2:-}
}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

assert_silent() {
  [ -z "$1" ] || fail "$2 (expected no output, got: $1)"
}

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (expected to contain '$2', got: $1)" ;;
  esac
}

day=86400000

# 1. Healthy, with no prior history. Must not fire a false regression.
out="$(run "$(blob $((28 * day)))")"
assert_silent "$out" "healthy with empty history should be silent"

# 2. Healthy again, unchanged. Steady state must stay quiet.
out="$(run "$(blob $((28 * day)))")"
assert_silent "$out" "unchanged healthy sample should be silent"

# 3. Rolled forward. Moving further out is good news, never an alert.
out="$(run "$(blob $((30 * day)))")"
assert_silent "$out" "expiry rolling forward should be silent"

# 4. Dropped into the banner window. Both the regression and the
#    banner-explainer should fire.
out="$(run "$(blob 26640000)")"   # 7.4h
assert_contains "$out" "BACKWARDS" "regression should be reported"
assert_contains "$out" "1 day" "should explain the Math.ceil 1-day rendering"
assert_contains "$out" "/login" "should tell the user what actually fixes it"

# 5. Already expired.
out="$(run "$(blob -3600000)")"
assert_contains "$out" "EXPIRED" "expired refresh token should be reported"

# 6. --quiet (SessionEnd) samples but never speaks.
before="$(wc -l < "$log")"
out="$(run "$(blob 26640000)" --quiet)"
after="$(wc -l < "$log")"
assert_silent "$out" "--quiet must not emit"
[ "$after" -gt "$before" ] || fail "--quiet must still append a sample"

# 7. A garbage credential blob must be survivable: silent, exit 0, no row.
before="$(wc -l < "$log")"
set +e
out="$(run 'not json at all')"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "garbage blob must still exit 0 (got $rc)"
assert_silent "$out" "garbage blob must be silent"
[ "$(wc -l < "$log")" -eq "$before" ] || fail "garbage blob must not append a sample"

# 8. Every emitted payload must be valid hook JSON with continue:true, or a
#    malformed line would break the session it is supposed to protect.
run "$(blob 3600000)" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
assert raw, "expected a payload"
d = json.loads(raw)
assert d.get("continue") is True, d
assert isinstance(d.get("systemMessage"), str) and d["systemMessage"], d
'

# 9. The log must stay machine-readable: one JSON object per line.
python3 -c '
import json, sys
for i, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if line:
        json.loads(line)
' "$log"

printf 'oauth-expiry-monitor: all checks passed\n'
