#!/usr/bin/env bash
# audit-claude-harness.sh must find a Codex plugin manifest without ripgrep.
# It used to call rg, which is absent from a plain bash PATH on this Mac, so a
# missing binary read as "no match" and the audit printed PASS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want exit $2, got $3)" >&2; fi; }

mkdir -p "$ROOT/repo/scripts" "$ROOT/repo/plug" "$ROOT/cfg"
cp "$HERE/audit-claude-harness.sh" "$ROOT/repo/scripts/"
touch "$ROOT/repo/README.md" "$ROOT/repo/CLAUDE.md"
NO_RG_PATH="/usr/bin:/bin"   # no ripgrep here
run() { PATH="$NO_RG_PATH" CLAUDE_CONFIG_DIR="$ROOT/cfg" bash "$ROOT/repo/scripts/audit-claude-harness.sh" "$@" >/dev/null 2>&1; echo $?; }

echo '{"name":"clean"}' > "$ROOT/repo/plug/plugin.json"
check "clean repo passes" 0 "$(run)"

echo '{"path":".codex-plugin/x"}' > "$ROOT/repo/plug/plugin.json"
check "Codex manifest fails without rg" 1 "$(run)"
echo '{"name":"clean"}' > "$ROOT/repo/plug/plugin.json"

echo '{"hooks":"install-codex"}' > "$ROOT/cfg/settings.json"
check "Codex wiring in installed settings fails without rg" 1 "$(run --installed)"
echo '{}' > "$ROOT/cfg/settings.json"
check "clean installed settings pass" 0 "$(run --installed)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
