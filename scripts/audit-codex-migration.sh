#!/usr/bin/env bash
# Audit a workspace migrating from Claude Code conventions to Codex conventions.

set -u

workspace="${1:-$PWD}"
strict="${2:-}"
config="${CODEX_HOME:-$HOME/.codex}/config.toml"
issues=0
legacy=0
instruction_budget=32768

if [ -f "$config" ]; then
  configured_budget="$(sed -n 's/^project_doc_max_bytes[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$config" | tail -1)"
  if [ -n "$configured_budget" ]; then instruction_budget="$configured_budget"; fi
fi

if [ ! -d "$workspace" ]; then
  echo "Workspace does not exist: $workspace" >&2
  exit 2
fi

workspace="$(cd "$workspace" && pwd)"
echo "Codex migration audit: $workspace"

while IFS= read -r claude_file; do
  dir="${claude_file%/CLAUDE.md}"
  if [ ! -f "$dir/AGENTS.md" ]; then
    printf 'LEGACY_ONLY %s\n' "${claude_file#"$workspace"/}"
    legacy=$((legacy + 1))
    if [ "$strict" = "--strict" ]; then issues=$((issues + 1)); fi
  fi
done < <(find "$workspace" \
  -type d \( -name .git -o -name node_modules -o -name .venv -o -name .codex -o \
  -name third-party -o -name vendor -o -name .agents -o -name .claude \) -prune -o \
  -type f -name CLAUDE.md -print | sort)

while IFS= read -r agents_file; do
  bytes="$(wc -c < "$agents_file" | tr -d ' ')"
  if [ "$bytes" -gt "$instruction_budget" ]; then
    printf 'LARGE_AGENTS %s (%s bytes)\n' "${agents_file#"$workspace"/}" "$bytes"
    issues=$((issues + 1))
  fi
done < <(find "$workspace" \
  -type d \( -name .git -o -name node_modules -o -name .venv -o -name .codex -o \
  -name third-party -o -name vendor -o -name .agents -o -name .claude \) -prune -o \
  -type f -name AGENTS.md -print | sort)

while IFS= read -r old_harness; do
  repo="${old_harness%/.claude-harness}"
  if [ ! -d "$repo/.codex-harness" ]; then
    printf 'LEGACY_HARNESS %s\n' "${old_harness#"$workspace"/}"
    legacy=$((legacy + 1))
    if [ "$strict" = "--strict" ]; then issues=$((issues + 1)); fi
  fi
done < <(find "$workspace" \
  -type d \( -name .git -o -name node_modules -o -name .venv -o -name .codex -o \
  -name third-party -o -name vendor -o -name .agents -o -name .claude \) -prune -o \
  -type d -name .claude-harness -print | sort)

if [ ! -f "$config" ]; then
  echo "MISSING_CONFIG $config"
  issues=$((issues + 1))
else
  if ! grep -Eq '^project_doc_fallback_filenames[[:space:]]*=.*CLAUDE\.md' "$config"; then
    echo "MISSING_FALLBACK project_doc_fallback_filenames does not include CLAUDE.md"
    issues=$((issues + 1))
  fi
  if ! grep -Eq '^project_doc_max_bytes[[:space:]]*=[[:space:]]*(65536|[1-9][0-9]{5,})' "$config"; then
    echo "LOW_INSTRUCTION_BUDGET set project_doc_max_bytes to at least 65536"
    issues=$((issues + 1))
  fi
fi

if [ "$issues" -eq 0 ]; then
  echo "PASS Codex compatibility checks passed ($legacy legacy surface(s) covered by fallback)"
  exit 0
fi

echo "SUMMARY $issues migration issue(s) found"
exit 1
