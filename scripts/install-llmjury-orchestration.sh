#!/usr/bin/env bash
# Install optional bidirectional Claude/Codex orchestration supplied by LLM-Jury.

set -eu

force=""
if [ "${1:-}" = "--force" ]; then
  force="--force"
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi

command -v llmjury >/dev/null 2>&1 || {
  echo "LLM-Jury is not installed; install llm-jury-verify first" >&2
  exit 1
}

if [ -n "$force" ]; then
  llmjury install-claude --force
  llmjury install-codex --force
else
  llmjury install-claude
  llmjury install-codex
fi

claude_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
codex_root="${CODEX_HOME:-$HOME/.codex}"
claude_skill="$claude_root/skills/llm-jury-delegate/SKILL.md"
codex_skill="$codex_root/skills/llm-jury-orchestrate/SKILL.md"

test -f "$claude_skill" || {
  echo "Claude delegation skill was not created: $claude_skill" >&2
  exit 1
}
test -f "$codex_skill" || {
  echo "Codex orchestration skill was not created: $codex_skill" >&2
  exit 1
}

echo "LLM-Jury orchestration ready"
echo "  Claude -> Codex: $claude_skill"
echo "  Codex -> Claude: $codex_skill"
echo "Restart both agent harnesses after the first install."
