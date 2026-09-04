#!/bin/bash
# Keep Team Nebula and Reddy2help work out of claude-mem.
#
# The claude-mem plugin is enabled in ~/.claude/settings.json and captures
# EVERY session unconditionally — SessionStart, UserPromptSubmit, PostToolUse,
# Stop, PreCompact and SessionEnd all write to the graph. It ships no env var or
# config that turns it off, so the only supported lever is settings precedence:
# user < project < local. A repo-local .claude/settings.local.json that sets the
# plugin false beats the user-level true.
#
# settings.local.json and not settings.json on purpose — the latter is committed,
# and dropping our memory config into a client's repository is not ours to do.
#
# Org identity is the git ORIGIN REMOTE, not the folder you opened (see
# ~/.claude/CLAUDE.md). A TMN repo cloned under ~/personal is still a TMN repo.
#
# Runs on SessionStart. Writing the file cannot affect the session that writes it:
# plugin enablement is resolved at startup. So the FIRST session in a newly
# cloned excluded repo still captures, and every session after it does not. The
# systemMessage says so rather than letting you assume otherwise.
set -uo pipefail

EXCLUDED_ORG_PATTERN='github\.com[:/]+(teamnebula-ai|Reddy2help)[/]'
PLUGIN="claude-mem@thedotmack"

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
origin=$(git -C "$root" remote get-url origin 2>/dev/null) || exit 0

grep -qiE "$EXCLUDED_ORG_PATTERN" <<<"$origin" || exit 0

settings="$root/.claude/settings.local.json"
# `.enabledPlugins[$p] // "unset"` would be wrong here: jq's // treats FALSE as
# empty, so the gated state reads as unset and the file gets rewritten every
# session. Test for the key and its value separately.
if [ -f "$settings" ] && jq -e --arg p "$PLUGIN" '.enabledPlugins | has($p) and (.[$p] == false)' "$settings" >/dev/null 2>&1; then
  exit 0   # already gated, and this session started with it applied
fi

mkdir -p "$root/.claude"
tmp=$(mktemp)
if [ -f "$settings" ]; then
  jq --arg p "$PLUGIN" '.enabledPlugins[$p] = false' "$settings" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
else
  jq -n --arg p "$PLUGIN" '{enabledPlugins: {($p): false}}' > "$tmp"
fi
mv "$tmp" "$settings"

# Keep it out of the repo's history — this is a machine-local preference.
gi="$root/.gitignore"
if [ -f "$gi" ] && ! grep -qxF ".claude/settings.local.json" "$gi"; then
  printf '\n.claude/settings.local.json\n' >> "$gi"
fi

org=$(sed -nE 's#.*github\.com[:/]+([^/]+)/.*#\1#p' <<<"$origin")
jq -n --arg org "$org" --arg f "$settings" '{
  systemMessage: ("Memory capture (claude-mem) gated off for \($org) — wrote \($f). Takes effect from the NEXT session in this repo; this one still captures.")
}'
