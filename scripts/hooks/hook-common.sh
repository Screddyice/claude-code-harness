#!/usr/bin/env bash

# Shared helpers for Claude Code and Codex lifecycle hooks.

hook_resolve_cwd() {
  local input="${1:-}"
  local cwd

  # Accept Claude/Codex (cwd) payloads.
  cwd="$(printf '%s' "$input" | python3 -c 'import json, sys
try:
    j = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
print(j.get("cwd") or "")' 2>/dev/null)"
  [ -z "$cwd" ] && cwd="${CODEX_PROJECT_DIR:-}"
  [ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true
}

hook_load_branch_context() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  HOOK_BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ -n "$HOOK_BRANCH" ] || return 1
  case "$HOOK_BRANCH" in main|master) return 1 ;; esac

  HOOK_ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$HOOK_ORIGIN_URL" ] || return 1

  # owner/repo for ORIGIN specifically. Every gh call below must be pinned to
  # this, because bare `gh` picks a remote by its own precedence and prefers
  # `upstream` when one exists — so in a fork it answers about the PARENT repo.
  # Observed 2026-08-12 in Screddyice/backdoor (a fork of ajsai47/backdoor):
  # an open PR on origin was reported as "no open pull request", and the Stop
  # hook blocked every single stop with no way to satisfy it. The PR existed
  # the whole time; the hook was asking the wrong repository.
  #
  # Derived with awk rather than a non-greedy regex: BSD sed rejects `+?`.
  # Handles both https://host/owner/repo(.git) and git@host:owner/repo(.git).
  HOOK_REPO_SLUG="$(printf '%s' "$HOOK_ORIGIN_URL" \
    | sed -e 's|\.git$||' -e 's|:|/|g' \
    | awk -F/ 'NF>=2 {print $(NF-1)"/"$NF}')"

  # Passed as an ARRAY, never as an unquoted ${VAR:+--repo "$VAR"}. That form
  # depends on word-splitting an unquoted expansion, which bash does and zsh
  # does not — so it silently becomes the single argument `--repo owner/name`
  # and gh rejects it with "unknown flag". These files carry a bash shebang but
  # are also sourced, and a helper that only works under one shell is a trap.
  # Expanded at every call site as ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"},
  # not the plain "${HOOK_GH_REPO_ARGS[@]}". /bin/bash on macOS is 3.2, where an
  # EMPTY array expanded under `set -u` aborts with "unbound variable" — and
  # auto-pr-push.sh runs `set -uo pipefail`. A slug that fails to parse would
  # otherwise turn a cosmetic miss into a dead hook.
  HOOK_GH_REPO_ARGS=()
  [ -n "$HOOK_REPO_SLUG" ] && HOOK_GH_REPO_ARGS=(--repo "$HOOK_REPO_SLUG")

  HOOK_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$HOOK_TOP" ] || return 1
  HOOK_REPO_DIR="$(basename "$HOOK_TOP")"

  local repo_identity
  repo_identity="$(printf '%s %s' "$HOOK_ORIGIN_URL" "$HOOK_REPO_DIR" | tr '[:upper:]' '[:lower:]')"
  case "$repo_identity" in *rs21*) return 1 ;; esac

  # The integration branch THIS branch forked from -- not a guessed default.
  #
  # This used to take the first of main/master that existed, which is wrong two
  # different ways. A repo whose integration branch is something else (nebos-v2
  # deploys `dev`; teamnebula.ai defaults to `staging`) had its "commits ahead"
  # measured against a ref the work does not belong on, and because `gh pr create`
  # was called with no --base, the PR then targeted the repo DEFAULT -- a third
  # ref, agreeing with neither. teamnebula-ai/nebos-v2#365 opened against `main`
  # in a repo where every PR targets `dev`.
  #
  # Scored by TOTAL DIVERGENCE, not by commits ahead. Derived per branch, so one
  # repo can serve both a `dev` flow and a `main` flow.
  #
  # "Fewest commits ahead" is the obvious metric and it ties constantly: a branch
  # cut from `main` with one commit is 1 ahead of `main` AND 1 ahead of `dev`, so
  # the tie falls to list order and half the repos get the wrong answer.
  #
  # Divergence separates them, because it also counts what the candidate has that
  # we do not:
  #
  #                        ahead  behind  total
  #   cut from main:  main    1      0       1   <- forked here
  #                   dev     1      1       2
  #   cut from dev:   dev     1      0       1   <- forked here
  #                   main    2      0       2
  #
  # The fork point is the candidate we have diverged from least in both
  # directions, which is exactly what a human reads off the network graph.
  # Remote-tracking refs are scored ALONE whenever any exist, and local branch
  # names are a fallback for a repo that has none.
  #
  # Mixing the two tiers is a correctness bug, not a style choice. A local `main`
  # can be arbitrarily stale, and a stale ref looks CLOSER on divergence than the
  # remote one precisely when it matters most: after a squash merge, origin/main
  # carries a commit this branch lacks (+1 behind) while the untouched local main
  # does not, so the local ref wins the score and the "base already contains this
  # tree" guard stops firing. That guard is what stops a second PR being opened for
  # already-merged work, so losing it re-opens the llm-jury#18 duplicate.
  local ref default_ref candidates remote_candidates counts ahead behind total best_total
  default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  remote_candidates=""
  # Order is the tie-break, and only the tie-break: divergence decides outright
  # whenever the branch really did fork from one of these. Trunk leads, because a
  # tie means "equally far from both" and trunk is the safer place to aim then.
  # origin/HEAD is first so a repo whose default is not named here still wins.
  for ref in $default_ref origin/main origin/master origin/dev origin/develop origin/staging; do
    [ -n "$ref" ] || continue
    git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 && remote_candidates="$remote_candidates $ref"
  done
  if [ -n "$remote_candidates" ]; then
    candidates="$remote_candidates"
  else
    candidates="main master dev develop staging"
  fi

  HOOK_BASE=""
  best_total=""
  for ref in $candidates; do
    [ -n "$ref" ] || continue
    git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
    # "<behind>\t<ahead>": commits on ref we lack, then commits on HEAD it lacks.
    counts="$(git rev-list --left-right --count "${ref}...HEAD" 2>/dev/null || true)"
    [ -n "$counts" ] || continue
    behind="$(printf '%s' "$counts" | awk '{print $1}')"
    ahead="$(printf '%s' "$counts" | awk '{print $2}')"
    case "$behind$ahead" in ''|*[!0-9]*) continue ;; esac
    total=$((behind + ahead))
    if [ -z "$best_total" ] || [ "$total" -lt "$best_total" ]; then
      best_total="$total"
      HOOK_BASE="$ref"
    fi
  done
  [ -n "$HOOK_BASE" ] || return 1

  # The branch name a PR can target: refs/remotes/origin/dev -> dev.
  HOOK_BASE_BRANCH="${HOOK_BASE#origin/}"

  HOOK_AHEAD="$(git rev-list --count "${HOOK_BASE}..HEAD" 2>/dev/null || echo 0)"
  [ "${HOOK_AHEAD:-0}" -gt 0 ] 2>/dev/null || return 1
  return 0
}

# True when this branch's CURRENT head is exactly what a merged PR landed.
#
# A squash merge produces one commit on the base that is an ancestor of nothing
# on the branch, so HOOK_AHEAD stays > 0 forever, while the PR is MERGED rather
# than open and an --state open lookup returns nothing. The branch then looks
# identical to work that never had a PR, and the Stop hook blocks every stop with
# no action that can satisfy it — deleting the local branch is the only exit, and
# nothing tells you that. Observed 2026-08-12 on Screddyice/jarvis after #18
# squash-merged.
#
# Keyed on the head SHA, exactly as auto-pr-push.sh does for the same reason: a
# branch REUSED for new commits has a different HEAD, so it correctly still
# needs a PR rather than coasting on the old merge.
hook_branch_already_merged() {
  local head_oid merged_oid
  head_oid="$(git rev-parse HEAD 2>/dev/null || true)"
  [ -n "$head_oid" ] || return 1

  merged_oid="$(gh pr list ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
    --head "$HOOK_BRANCH" --state merged \
    --json headRefOid --jq '.[0].headRefOid // empty' 2>/dev/null)"

  [ -n "$merged_oid" ] && [ "$merged_oid" = "$head_oid" ]
}

hook_load_pr_status() {
  HOOK_PR_STATUS=""
  HOOK_PR_COUNT="0"

  if ! command -v gh >/dev/null 2>&1; then
    HOOK_PR_STATUS="gh_missing"
    return 0
  fi

  HOOK_PR_COUNT="$(gh pr list ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
    --head "$HOOK_BRANCH" --state open --json number --jq 'length' 2>/dev/null)"
  if [ $? -ne 0 ]; then
    HOOK_PR_STATUS="gh_error"
  elif [ "${HOOK_PR_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    HOOK_PR_STATUS="has_pr"
  elif hook_branch_already_merged; then
    # Distinct from has_pr on purpose. "Landed already" and "has a review surface
    # open" are different facts, and a consumer that logs or reports should be
    # able to tell them apart.
    HOOK_PR_STATUS="merged_pr"
  else
    HOOK_PR_STATUS="needs_pr"
  fi
}

hook_json_string() {
  local value="$1"
  VALUE="$value" python3 -c 'import json, os; print(json.dumps(os.environ["VALUE"]))'
}
