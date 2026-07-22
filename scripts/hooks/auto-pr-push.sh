#!/usr/bin/env bash

# Shared PostToolUse hook. Pushes work branches for owned GitHub organizations
# and opens a draft pull request when the branch has no open PR.

set -uo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=hook-common.sh
. "$script_dir/hook-common.sh"

log_dir="${HARNESS_HOOK_LOG_DIR:-$HOME/.cache/claude-code-harness}"
log="$log_dir/auto-pr-push.log"
allowed_owners="${HARNESS_PR_OWNERS:-}"
[ -n "$allowed_owners" ] || exit 0

input="$(cat 2>/dev/null || true)"
hook_resolve_cwd "$input"
hook_load_branch_context || exit 0

owner="$(printf '%s' "$HOOK_ORIGIN_URL" \
  | sed -E 's#^git@[^:]+:##; s#^ssh://git@[^/]+/##; s#^https?://[^/]+/##' \
  | cut -d/ -f1 | tr '[:upper:]' '[:lower:]')"
[ -n "$owner" ] || exit 0
case " $allowed_owners " in
  *" $owner "*) : ;;
  *) exit 0 ;;
esac

gitdir="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] \
   || [ -f "$gitdir/MERGE_HEAD" ] || [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then
  exit 0
fi

lock_key="$(printf '%s#%s' "$HOOK_TOP" "$HOOK_BRANCH" | tr '/ .' '___')"
lockdir="${TMPDIR:-/tmp}/autoprpush-${lock_key}.lock"
mkdir "$lockdir" 2>/dev/null || exit 0
mkdir -p "$log_dir" 2>/dev/null || { rmdir "$lockdir" 2>/dev/null; exit 0; }

(
  trap 'rmdir "$lockdir" 2>/dev/null' EXIT
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "${AUTO_PR_PUSH_DRYRUN:-0}" = "1" ]; then
    printf '%s [DRYRUN] %s@%s (owner=%s, ahead=%s) -> would push + ensure draft PR\n' \
      "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" "$owner" "$HOOK_AHEAD" >>"$log" 2>&1
    exit 0
  fi

  git push -u origin "HEAD:$HOOK_BRANCH" >>"$log" 2>&1

  pr_count="$(gh pr list --head "$HOOK_BRANCH" --state open --json number --jq 'length' 2>>"$log")"
  if [ "${pr_count:-0}" = "0" ]; then
    if gh pr create --draft --fill --head "$HOOK_BRANCH" >>"$log" 2>&1; then
      printf '%s [ok] opened draft PR for %s@%s\n' "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" >>"$log" 2>&1
    else
      printf '%s [warn] push ok but could not open PR for %s@%s\n' \
        "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" >>"$log" 2>&1
    fi
  else
    printf '%s [ok] pushed %s@%s (PR already open)\n' "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" >>"$log" 2>&1
  fi
) >/dev/null 2>&1 &
disown 2>/dev/null || true

exit 0
