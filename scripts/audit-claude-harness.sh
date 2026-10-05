#!/usr/bin/env bash
# Read-only audit for the Claude harness and its plugin boundary.
set -uo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

[ -f "$root/README.md" ] || fail "missing $root/README.md"
[ -f "$root/CLAUDE.md" ] || fail "missing $root/CLAUDE.md"
[ -f "$root/holyclaude-cloud/.claude-plugin/plugin.json" ] ||
  fail "Claude plugin manifest is missing"

if find "$root" -type f \( -name plugin.json -o -name marketplace.json \) -print 2>/dev/null |
   while IFS= read -r manifest; do
     rg -q '\.codex-plugin|codex plugin marketplace|install-codex' "$manifest" &&
       { printf '%s\n' "$manifest"; exit 0; }
   done | grep -q .; then
  fail "Claude harness contains a Codex plugin manifest"
fi

if find "$root" -type d \( -name .codex-plugin -o -name marketplace \) -print -quit 2>/dev/null |
   grep -q .; then
  fail "Claude harness contains a Codex plugin directory"
fi

if [ "${1:-}" = "--installed" ]; then
  settings="$claude_home/settings.json"
  [ -f "$settings" ] || fail "missing installed Claude settings: $settings"
  if [ -f "$settings" ] && rg -qi 'codex-plugin|codex marketplace|install-codex' "$settings"; then
    fail "$settings contains Codex plugin wiring"
  fi
fi

if [ "$failures" -eq 0 ]; then
  printf 'PASS: Claude harness plugin boundary (%s)\n' "$root"
  exit 0
fi
printf 'Claude harness audit found %d issue(s)\n' "$failures" >&2
exit 1
