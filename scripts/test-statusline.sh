#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATUSLINE="$ROOT/scripts/statusline.sh"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline.XXXXXX")

FAKE_ROUTER_PID=""
cleanup() {
  [ -n "$FAKE_ROUTER_PID" ] && kill "$FAKE_ROUTER_PID" 2>/dev/null
  rm -r "$FIXTURE"
}
trap cleanup EXIT

# A PATH that holds everything the script calls except jq. Symlinking the real
# binaries keeps this honest: the only thing missing is the one dependency.
NOJQ_BIN="$FIXTURE/nojq-bin"
mkdir -p "$NOJQ_BIN"
for tool in cat basename xargs tr; do
  tool_path=$(command -v "$tool") || continue
  ln -s "$tool_path" "$NOJQ_BIN/$tool"
done

failures=0

run_statusline() {
  local model=$1
  local base_url=${2:-}
  local proxy_url=${3:-}
  local state_file=${4:-$FIXTURE/absent-state.json}
  local session_model=${5:-}
  printf '{"session_id":"fixture","model":{"display_name":"%s"},"cwd":"/tmp"}' "$model" |
    ANTHROPIC_BASE_URL="$base_url" \
    HTTPS_PROXY="$proxy_url" \
    BACKDOOR_STATE_FILE="$state_file" \
    QWEN_SESSION_MODEL="$session_model" \
    "$STATUSLINE"
}

# A process whose `ps -o command=` matches the router patterns the status line
# accepts. Faking the PID alone is not enough, and that is the point: a stale
# state file naming a recycled PID must not be able to claim the router is up.
start_fake_router() {
  local bin="$FIXTURE/backdoor-router"
  if [ ! -x "$bin" ]; then
    printf '#!/bin/bash\nsleep 30\n' > "$bin"
    chmod +x "$bin"
  fi
  # Detach every fd: a background child that still holds this command
  # substitution's stdout keeps it open until the child exits, which hangs the
  # whole test run for the length of the sleep.
  "$bin" >/dev/null 2>&1 </dev/null &
  FAKE_ROUTER_PID=$!
  printf '%s' "$FAKE_ROUTER_PID"
}

write_state() {
  local path=$1 active=$2 pid=$3 sources=${4:-'["anthropic"]'}
  cat > "$path" <<JSON
{"failover_active": $active, "reason": "ConnectTimeout", "active_sources": $sources,
 "reasons": {"anthropic": "ConnectTimeout"}, "updated_at": 1788800000, "pid": $pid}
JSON
}

run_statusline_without_jq() {
  printf '{"session_id":"fixture","model":{"display_name":"Opus 5"},"cwd":"/tmp"}' |
    env -i PATH="$NOJQ_BIN" HOME="$HOME" /bin/bash "$STATUSLINE"
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

out=$(run_statusline "Opus 5")
expect_contains "cloud model name" "$out" "Opus 5"

# Routing environment ALONE must never produce a badge. The breaker state file
# is the only thing that knows a session is actually being served locally, and
# a leftover proxy variable from a retired router must not be able to claim it.
out=$(run_statusline "Opus 5" "" "http://127.0.0.1:8084")
expect_absent "stale proxy env, no state" "$out" "LOCAL TIER"

out=$(run_statusline "Opus 5" "http://127.0.0.1:8083" "")
expect_absent "stale base url env, no state" "$out" "LOCAL TIER"

out=$(run_statusline "Opus 5" "https://api.anthropic.com" "")
expect_absent "direct cloud" "$out" "LOCAL TIER"

# The badge: routed, breaker open on anthropic, and a live router process.
router_pid=$(start_fake_router)
active_state="$FIXTURE/active.json"
write_state "$active_state" true "$router_pid"

out=$(run_statusline "Opus 5" "http://127.0.0.1:8083" "" "$active_state")
expect_contains "failover active shows the tier" "$out" "LOCAL TIER"

# Same live router, but the breaker is closed — the session is back on Claude
# and the badge has to go away on its own.
closed_state="$FIXTURE/closed.json"
write_state "$closed_state" false "$router_pid"
out=$(run_statusline "Opus 5" "http://127.0.0.1:8083" "" "$closed_state")
expect_absent "breaker closed" "$out" "LOCAL TIER"

# Breaker open on a DIFFERENT upstream (Codex) says nothing about this session.
codex_state="$FIXTURE/codex.json"
write_state "$codex_state" true "$router_pid" '["codex"]'
out=$(run_statusline "Opus 5" "http://127.0.0.1:8083" "" "$codex_state")
expect_absent "another upstream's breaker" "$out" "LOCAL TIER"

# Breaker state is global to the router, so a session that is NOT routed through
# it must not inherit the badge from a session that is.
out=$(run_statusline "Opus 5" "" "" "$active_state")
expect_absent "unrouted session, active state" "$out" "LOCAL TIER"

kill "$router_pid" 2>/dev/null
# Give the kill a moment to land before asserting the state file is stale.
while kill -0 "$router_pid" 2>/dev/null; do sleep 0.1; done

# The router is gone but its state file survives, still saying failover_active.
# This is the stale-file case, and it must fail closed.
out=$(run_statusline "Opus 5" "http://127.0.0.1:8083" "" "$active_state")
expect_absent "dead router, stale state" "$out" "LOCAL TIER"

# Garbage must not crash the line or produce a badge.
bad_state="$FIXTURE/bad.json"
printf 'not json at all\n' > "$bad_state"
out=$(run_statusline "Opus 5" "http://127.0.0.1:8083" "" "$bad_state")
expect_absent "malformed state" "$out" "LOCAL TIER"
expect_contains "malformed state still reports the model" "$out" "Opus 5"

# A deliberate `/model qwen` is a choice, not an outage. It names the model and
# must not imply the router failed anything over.
out=$(run_statusline "qwen")
expect_contains "local model" "$out" "QWEN LOCAL"
expect_absent "local model is not a failover claim" "$out" "LOCAL TIER"

# `qwen claude` serves the session from Ollama under a borrowed catalog id, so
# the payload says "Haiku 4.5" for a model Anthropic never saw. The name is the
# one thing on the line that is false, so the line must not repeat it.
out=$(run_statusline "Haiku 4.5" "http://127.0.0.1:11434" "" "" "qwen3.8:27b-obliterated")
expect_contains "local session names the local model" "$out" "QWEN LOCAL"
expect_absent "local session drops the borrowed catalog name" "$out" "Haiku 4.5"
expect_absent "a local session is not a failover claim" "$out" "LOCAL TIER"

# Someone can point a session at Ollama by hand, with no wrapper to label it.
out=$(run_statusline "Haiku 4.5" "http://127.0.0.1:11434")
expect_contains "an unlabelled ollama session is still named local" "$out" "LOCAL"
expect_absent "an unlabelled ollama session drops the catalog name" "$out" "Haiku 4.5"

# Any other local tag is named rather than called Qwen.
out=$(run_statusline "Haiku 4.5" "" "" "" "gemma3:12b")
expect_contains "a non-qwen local model is named" "$out" "LOCAL · gemma3:12b"

# The ordinary cloud session is the common case and must stay untouched.
out=$(run_statusline "Haiku 4.5" "https://api.anthropic.com")
expect_contains "a cloud session keeps its model name" "$out" "Haiku 4.5"
expect_absent "a cloud session gets no local badge" "$out" "LOCAL"

# Without jq the script cannot read the model. It must say that out loud: the
# old version printed an empty line and exited 0, which is indistinguishable
# from a healthy session.
out=$(run_statusline_without_jq)
expect_contains "missing jq announces itself" "$out" "STATUSLINE BLIND"

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf 'PASS status-line fixtures\n'
