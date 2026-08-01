#!/usr/bin/env bash
# Resolve the installed claude-mem plugin root (latest semver with worker scripts).
set -euo pipefail

if [[ -n "${CLAUDE_MEM_PLUGIN_ROOT:-}" && -f "${CLAUDE_MEM_PLUGIN_ROOT}/scripts/worker-service.cjs" ]]; then
  printf '%s\n' "${CLAUDE_MEM_PLUGIN_ROOT%/}"
  exit 0
fi

if [[ -L "${HOME}/.grok/claude-mem-plugin" || -d "${HOME}/.grok/claude-mem-plugin" ]]; then
  candidate=$(readlink -f "${HOME}/.grok/claude-mem-plugin" 2>/dev/null || readlink "${HOME}/.grok/claude-mem-plugin" 2>/dev/null || true)
  if [[ -n "${candidate:-}" && -f "${candidate}/scripts/worker-service.cjs" ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
fi

best=""
best_key=""
for base in \
  "${HOME}/.claude/plugins/cache/thedotmack/claude-mem" \
  "${HOME}/.codex/plugins/cache/thedotmack/claude-mem"
do
  [[ -d "$base" ]] || continue
  for dir in "$base"/[0-9]*/; do
    [[ -d "$dir" ]] || continue
    [[ -e "${dir}.orphaned_at" ]] && continue
    [[ -f "${dir}scripts/worker-service.cjs" ]] || continue
    ver=$(basename "${dir%/}")
    # pad numeric parts for lexical max
    key=$(printf '%s' "$ver" | awk -F. '{printf "%08d%08d%08d\n", $1+0,$2+0,$3+0}')
    if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
      best_key=$key
      best=${dir%/}
    fi
  done
done

if [[ -n "$best" ]]; then
  printf '%s\n' "$best"
  exit 0
fi

market="${HOME}/.claude/plugins/marketplaces/thedotmack/plugin"
if [[ -f "$market/scripts/worker-service.cjs" ]]; then
  printf '%s\n' "$market"
  exit 0
fi

echo "claude-mem: installation not found" >&2
exit 1
