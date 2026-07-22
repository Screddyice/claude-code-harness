#!/usr/bin/env bash

# Claude Code Stop-hook adapter for the shared branch/PR checks.

set -uo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=hook-common.sh
. "$script_dir/hook-common.sh"

input="$(cat 2>/dev/null || true)"
if printf '%s' "$input" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

hook_resolve_cwd "$input"
hook_load_branch_context || exit 0
hook_load_pr_status

case "$HOOK_PR_STATUS" in
  has_pr) exit 0 ;;
  gh_missing)
    message="PR-tracking rule: branch '$HOOK_BRANCH' has $HOOK_AHEAD commit(s) with no PR, and 'gh' is not installed, so Claude cannot verify or create one. Install gh or open the PR manually."
    printf '{"systemMessage":%s}\n' "$(hook_json_string "$message")"
    exit 0
    ;;
  gh_error)
    message="PR-tracking rule: GitHub could not confirm an open PR on '$HOOK_BRANCH' ($HOOK_AHEAD commit(s) ahead). Check gh authentication and open the PR when the connection is available."
    printf '{"systemMessage":%s}\n' "$(hook_json_string "$message")"
    exit 0
    ;;
esac

reason="HARDLINE RULE: branch '$HOOK_BRANCH' has $HOOK_AHEAD commit(s) ahead of $HOOK_BASE but no open pull request. Run \`gh pr create --head $HOOK_BRANCH --fill\` and add --draft if the work is unfinished. RS21 repositories are exempt."
printf '{"decision":"block","reason":%s}\n' "$(hook_json_string "$reason")"
