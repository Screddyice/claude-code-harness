#!/usr/bin/env bash

# Shared helpers for Claude Code and Codex lifecycle hooks.

hook_resolve_cwd() {
  local input="${1:-}"
  local cwd

  # Accept Claude/Codex (cwd) and Grok (cwd / workspaceRoot) payloads.
  cwd="$(printf '%s' "$input" | python3 -c 'import json, sys
try:
    j = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
print(j.get("cwd") or j.get("workspaceRoot") or j.get("workspace_root") or "")' 2>/dev/null)"
  [ -z "$cwd" ] && cwd="${CODEX_PROJECT_DIR:-}"
  [ -z "$cwd" ] && cwd="${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true
}

hook_load_branch_context() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  HOOK_BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ -n "$HOOK_BRANCH" ] || return 1
  case "$HOOK_BRANCH" in main|master) return 1 ;; esac

  HOOK_ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$HOOK_ORIGIN_URL" ] || return 1

  HOOK_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$HOOK_TOP" ] || return 1
  HOOK_REPO_DIR="$(basename "$HOOK_TOP")"

  local repo_identity
  repo_identity="$(printf '%s %s' "$HOOK_ORIGIN_URL" "$HOOK_REPO_DIR" | tr '[:upper:]' '[:lower:]')"
  case "$repo_identity" in *rs21*) return 1 ;; esac

  HOOK_BASE=""
  local ref
  for ref in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      HOOK_BASE="$ref"
      break
    fi
  done
  [ -n "$HOOK_BASE" ] || return 1

  HOOK_AHEAD="$(git rev-list --count "${HOOK_BASE}..HEAD" 2>/dev/null || echo 0)"
  [ "${HOOK_AHEAD:-0}" -gt 0 ] 2>/dev/null || return 1
  return 0
}

hook_load_pr_status() {
  HOOK_PR_STATUS=""
  HOOK_PR_COUNT="0"

  if ! command -v gh >/dev/null 2>&1; then
    HOOK_PR_STATUS="gh_missing"
    return 0
  fi

  HOOK_PR_COUNT="$(gh pr list --head "$HOOK_BRANCH" --state open --json number --jq 'length' 2>/dev/null)"
  if [ $? -ne 0 ]; then
    HOOK_PR_STATUS="gh_error"
  elif [ "${HOOK_PR_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    HOOK_PR_STATUS="has_pr"
  else
    HOOK_PR_STATUS="needs_pr"
  fi
}

hook_json_string() {
  local value="$1"
  VALUE="$value" python3 -c 'import json, os; print(json.dumps(os.environ["VALUE"]))'
}
