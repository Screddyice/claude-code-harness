#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATUSLINE="$ROOT/scripts/statusline.sh"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline.XXXXXX")

cleanup() { rm -r "$FIXTURE"; }
trap cleanup EXIT

# A PATH that holds everything the script calls except jq.
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
  local session_model=${3:-}
  printf '{"session_id":"fixture","model":{"display_name":"%s"},"cwd":"/tmp"}' "$model" |
    ANTHROPIC_BASE_URL="$base_url" QWEN_SESSION_MODEL="$session_model" "$STATUSLINE"
}
run_statusline_without_jq() {
  printf '{"session_id":"fixture","model":{"display_name":"Opus 5"},"cwd":"/tmp"}' |
    env -i PATH="$NOJQ_BIN" HOME="$HOME" /bin/bash "$STATUSLINE"
}
expect_contains() { local label=$1 output=$2 expected=$3; [[ "$output" == *"$expected"* ]] || { printf 'FAIL %s: expected %q in %q\n' "$label" "$expected" "$output"; failures=$((failures + 1)); }; }
expect_absent() { local label=$1 output=$2 forbidden=$3; [[ "$output" != *"$forbidden"* ]] || { printf 'FAIL %s: found %q in %q\n' "$label" "$forbidden" "$output"; failures=$((failures + 1)); }; }

out=$(run_statusline "Opus 5"); expect_contains "cloud model name" "$out" "Opus 5"
out=$(run_statusline "qwen"); expect_contains "local model" "$out" "QWEN LOCAL"; expect_absent "local model is not a failover claim" "$out" "LOCAL TIER"
out=$(run_statusline "Haiku 4.5" "http://127.0.0.1:11434" "qwen3.8:27b-obliterated"); expect_contains "local session names the local model" "$out" "QWEN LOCAL"; expect_absent "local session drops borrowed catalog name" "$out" "Haiku 4.5"
out=$(run_statusline "Haiku 4.5" "http://127.0.0.1:11434"); expect_contains "unlabelled ollama session is local" "$out" "LOCAL"; expect_absent "unlabelled ollama drops catalog name" "$out" "Haiku 4.5"
out=$(run_statusline "Haiku 4.5" "" "gemma3:12b"); expect_contains "non-qwen local model is named" "$out" "LOCAL · gemma3:12b"
out=$(run_statusline "Haiku 4.5" "https://api.anthropic.com"); expect_contains "cloud session keeps model" "$out" "Haiku 4.5"; expect_absent "cloud session gets no local badge" "$out" "LOCAL"
out=$(run_statusline_without_jq); expect_contains "missing jq announces itself" "$out" "STATUSLINE BLIND"

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf 'PASS status-line fixtures\n'
