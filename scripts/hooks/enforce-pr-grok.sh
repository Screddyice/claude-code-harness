#!/usr/bin/env bash

# Grok Stop-hook adapter for the shared branch/PR checks.
#
# Grok accepts Claude Code's stop-gate JSON ({"decision":"block","reason":...}).
# Differences vs Claude: camelCase stdin (stopHookActive, reason), plus an
# observe-only Stop fire at session end that must be ignored (reason != end_turn).
# Intentionally does NOT run the local Ollama diff reviewer — that load panicked
# this host when wired through Grok (see README "Grok harness support").

set -uo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=hook-common.sh
. "$script_dir/hook-common.sh"

input="$(cat 2>/dev/null || true)"

# Only gate genuine turn ends. Session-end Stop fires are observe-only.
reason="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("reason") or "")
except Exception:
    print("")' 2>/dev/null)"
[ -z "$reason" ] || [ "$reason" = "end_turn" ] || exit 0

# Avoid a second block after the agent already continued once this turn.
# Grok: stopHookActive; Claude-compat snake_case also accepted.
if printf '%s' "$input" | python3 -c 'import json,sys
try:
    j=json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
active=j.get("stopHookActive")
if active is None:
    active=j.get("stop_hook_active")
raise SystemExit(0 if active is True else 1)' 2>/dev/null; then
  exit 0
fi

hook_resolve_cwd "$input"
hook_load_branch_context || exit 0
hook_load_pr_status

case "$HOOK_PR_STATUS" in
  has_pr) exit 0 ;;
  # Already landed via squash merge — nothing to open. See
  # hook_branch_already_merged() for why an --state open lookup cannot see this.
  merged_pr) exit 0 ;;
  gh_missing)
    message="PR-tracking rule: branch '$HOOK_BRANCH' has $HOOK_AHEAD commit(s) with no PR, and 'gh' is not installed, so Grok cannot verify or create one. Install gh or open the PR manually."
    printf '{"systemMessage":%s}\n' "$(hook_json_string "$message")"
    exit 0
    ;;
  gh_error)
    message="PR-tracking rule: GitHub could not confirm an open PR on '$HOOK_BRANCH' ($HOOK_AHEAD commit(s) ahead). Check gh authentication and open the PR when the connection is available."
    printf '{"systemMessage":%s}\n' "$(hook_json_string "$message")"
    exit 0
    ;;
esac

reason_msg="HARDLINE RULE: branch '$HOOK_BRANCH' has $HOOK_AHEAD commit(s) ahead of $HOOK_BASE but no open pull request. Run \`gh pr create --head $HOOK_BRANCH --fill\` and add --draft if the work is unfinished. RS21 repositories are exempt."
printf '{"decision":"block","reason":%s}\n' "$(hook_json_string "$reason_msg")"
