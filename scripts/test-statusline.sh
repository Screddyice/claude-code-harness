#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATUSLINE="$ROOT/scripts/statusline.sh"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline.XXXXXX")

cleanup() {
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
  printf '{"session_id":"fixture","model":{"display_name":"%s"},"cwd":"/tmp"}' "$model" |
    ANTHROPIC_BASE_URL="$base_url" \
    HTTPS_PROXY="$proxy_url" \
    "$STATUSLINE"
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

# Backdoor was removed from this machine on 2026-09-10. No environment may
# revive a routing badge, including the proxy and base-URL values the retired
# router used, so a stale env var cannot make the status line lie.
out=$(run_statusline "Opus 5" "" "http://127.0.0.1:8084")
expect_absent "stale proxy env" "$out" "BACKDOOR"

out=$(run_statusline "Opus 5" "http://127.0.0.1:8083" "")
expect_absent "stale base url env" "$out" "BACKDOOR"

out=$(run_statusline "Opus 5" "https://api.anthropic.com" "")
expect_absent "direct cloud" "$out" "BACKDOOR"

# A locally served model still names itself, which is now a plain model label
# rather than a claim about routing.
out=$(run_statusline "qwen")
expect_contains "local model" "$out" "QWEN LOCAL"
expect_absent "local model" "$out" "BACKDOOR"

# Without jq the script cannot read the model. It must say that out loud: the
# old version printed an empty line and exited 0, which is indistinguishable
# from a healthy session.
out=$(run_statusline_without_jq)
expect_contains "missing jq announces itself" "$out" "STATUSLINE BLIND"

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf 'PASS status-line fixtures\n'
