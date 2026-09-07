#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATUSLINE="$ROOT/scripts/statusline.sh"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline.XXXXXX")
MOCK_BIN="$FIXTURE/bin"
mkdir -p "$MOCK_BIN"

sleep 30 &
LIVE_PID=$!

cleanup() {
  kill "$LIVE_PID" 2>/dev/null || true
  wait "$LIVE_PID" 2>/dev/null || true
  rm -r "$FIXTURE"
}
trap cleanup EXIT

cat > "$MOCK_BIN/ps" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"-o command="* ]] && [[ "$*" == *"-p $STATUSLINE_TEST_PID"* ]]; then
  case "${STATUSLINE_TEST_PS_MODE:-router}" in
    router) printf '%s\n' '/opt/homebrew/bin/python3 -m src.proxy.serve' ;;
    lookalike) printf '%s\n' '/usr/bin/sleep backdoor-router-not-really' ;;
    *) printf '%s\n' '/usr/bin/sleep 30' ;;
  esac
  exit 0
fi
exec /bin/ps "$@"
MOCK
chmod +x "$MOCK_BIN/ps"

failures=0

run_statusline() {
  local model=$1
  local base_url=$2
  local proxy_url=$3
  local state_file=$4
  local ps_mode=${5:-router}
  printf '{"session_id":"fixture","model":{"display_name":"%s"},"cwd":"/tmp"}' "$model" |
    PATH="$MOCK_BIN:$PATH" \
    STATUSLINE_TEST_PID="$LIVE_PID" \
    STATUSLINE_TEST_PS_MODE="$ps_mode" \
    BACKDOOR_STATE_FILE="$state_file" \
    ANTHROPIC_BASE_URL="$base_url" \
    HTTPS_PROXY="$proxy_url" \
    "$STATUSLINE"
}

expect_contains() {
  local label=$1
  local output=$2
  local expected=$3
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL %s: expected %q in %q\n' "$label" "$expected" "$output"
    failures=$((failures + 1))
  fi
}

expect_absent() {
  local label=$1
  local output=$2
  local forbidden=$3
  if [[ "$output" == *"$forbidden"* ]]; then
    printf 'FAIL %s: found %q in %q\n' "$label" "$forbidden" "$output"
    failures=$((failures + 1))
  fi
}

INACTIVE="$FIXTURE/inactive.json"
ACTIVE="$FIXTURE/active.json"
CODEX_ONLY="$FIXTURE/codex-only.json"
MALFORMED="$FIXTURE/malformed.json"
DEAD="$FIXTURE/dead.json"
UNSUPPORTED="$FIXTURE/unsupported.json"

printf '{"failover_active":false,"active_sources":[],"pid":%s}\n' "$LIVE_PID" > "$INACTIVE"
printf '{"failover_active":true,"active_sources":["anthropic"],"pid":%s}\n' "$LIVE_PID" > "$ACTIVE"
printf '{"failover_active":true,"active_sources":["codex"],"pid":%s}\n' "$LIVE_PID" > "$CODEX_ONLY"
printf '{broken json\n' > "$MALFORMED"
printf '{"failover_active":true,"active_sources":["anthropic"],"pid":999999}\n' > "$DEAD"
printf '{"failover_active":true,"pid":%s}\n' "$LIVE_PID" > "$UNSUPPORTED"

before_active=$(shasum -a 256 "$ACTIVE" | awk '{print $1}')

out=$(run_statusline "Opus 5" "" "http://127.0.0.1:8084" "$INACTIVE")
expect_absent "routed cloud" "$out" "BACKDOOR"

out=$(run_statusline "Opus 5" "https://api.anthropic.com" "" "$INACTIVE")
expect_contains "direct cloud" "$out" "BACKDOOR OFF"
expect_absent "direct cloud" "$out" "BACKDOOR ON"

out=$(run_statusline "Qwen" "http://127.0.0.1:8083" "" "$INACTIVE")
expect_contains "deliberate local" "$out" "QWEN LOCAL"
expect_absent "deliberate local" "$out" "BACKDOOR ON"

out=$(run_statusline "Opus 5" "" "http://127.0.0.1:8084" "$ACTIVE")
expect_contains "active Anthropic failover" "$out" "QWEN LOCAL"
expect_contains "active Anthropic failover" "$out" "BACKDOOR ON"

out=$(run_statusline "Opus 5" "https://api.anthropic.com" "" "$ACTIVE")
expect_contains "unrouted during global failover" "$out" "BACKDOOR OFF"
expect_absent "unrouted during global failover" "$out" "BACKDOOR ON"

for fixture in "$CODEX_ONLY" "$MALFORMED" "$DEAD" "$UNSUPPORTED" "$FIXTURE/missing.json"; do
  out=$(run_statusline "Opus 5" "" "http://127.0.0.1:8084" "$fixture")
  expect_absent "fail-closed state $(basename "$fixture")" "$out" "BACKDOOR ON"
done

out=$(run_statusline "Opus 5" "" "http://127.0.0.1:8084" "$ACTIVE" "wrong-process")
expect_absent "wrong process" "$out" "BACKDOOR ON"

out=$(run_statusline "Opus 5" "" "http://127.0.0.1:8084" "$ACTIVE" "lookalike")
expect_absent "lookalike process" "$out" "BACKDOOR ON"

after_active=$(shasum -a 256 "$ACTIVE" | awk '{print $1}')
if [ "$before_active" != "$after_active" ]; then
  printf 'FAIL status line changed the breaker state fixture\n'
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf 'PASS status-line fixtures\n'
