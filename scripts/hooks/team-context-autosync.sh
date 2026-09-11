#!/usr/bin/env bash
# team-context-autosync.sh — commit + push memory/ and projects-context/ to the
# CURRENT branch of team-context. No dedicated branch, no auto-PR.
#
# Replaces tmn-skills' memory-autosync.sh, which died on 2026-08-31 when the
# tree it lived in (~/moonshot/...) stopped existing. Nothing noticed for ten
# days and 22 records piled up uncommitted; its last run had also stranded an
# open PR (#725) carrying a record that existed nowhere else. Founder decision
# 2026-09-11: commit and push to whatever branch the session is already on, and
# never open a PR — a PR nobody watches is how #725 happened.
#
# Usage: team-context-autosync.sh [sync|now|pause|resume|status]
#   sync    commit+push unless paused   (what the Stop hook calls)
#   now     same, ignores the pause flag
set -uo pipefail

TC="${TEAM_CONTEXT_DIR:-$HOME/TeamNebula/team-context}"
CMD="${1:-sync}"
LOCK="$TC/.memory-autosync.lock"
LOG="$TC/.memory-autosync.log"
PAUSE="$TC/.memory-autosync-paused"
PATHS=(memory projects-context)

[ -d "$TC/.git" ] || exit 0

log() {
  echo "$(date '+%F %T') $*" >> "$LOG"
  tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}
pending() { git -C "$TC" status --porcelain -- "${PATHS[@]}" 2>/dev/null; }
ahead_of_upstream() {
  local upstream
  upstream="$(git -C "$TC" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || {
    printf '0'
    return 0
  }
  git -C "$TC" rev-list --count "$upstream..HEAD" 2>/dev/null || printf '0'
}
push_branch() {
  local branch="$1"
  if git -C "$TC" push -q origin "$branch" 2>/dev/null; then
    log "pushed $(git -C "$TC" rev-parse --short HEAD) -> $branch"
  else
    log "fail: push (offline or non-fast-forward) — committed locally, retries next run"
  fi
}

# Named-individual email addresses must never be auto-committed. The README
# rule already existed and failed silently on 2026-09-10 — a client contact's
# address reached records.jsonl because agents append records with nobody
# looking. Role and vendor addresses (support@, admin@) are fine, and so are
# org-domain addresses; anything else stops the sync rather than shipping it.
pii_hits() {
  git -C "$TC" diff --cached -- "${PATHS[@]}" 2>/dev/null \
    | grep '^+' | grep -v '^+++' \
    | cut -c2- \
    | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    | grep -viE '^(admin|support|info|hello|noreply|no-reply|contact|sales|team|help|billing|security)@' \
    | grep -viE '@teamnebula\.ai$' \
    | sort -u
}

sync() {
  local forced="${1:-}"
  if [ -f "$PAUSE" ] && [ "$forced" != "force" ]; then
    log "skipped: paused"; return 0
  fi

  mkdir "$LOCK" 2>/dev/null || { log "skipped: lock held"; return 0; }
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT

  local branch
  branch="$(git -C "$TC" symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
    log "skipped: detached HEAD"; return 0; }

  # main is protected upstream; pushing there fails noisily and a sync must not
  # be the thing that tries. Records stay committed locally either way.
  case "$branch" in
    main|master)
      log "skipped: on $branch (protected) — stage a memory/ branch to resume syncing"
      return 0 ;;
  esac

  if [ -z "$(pending)" ]; then
    [ "$(ahead_of_upstream)" -gt 0 ] && push_branch "$branch"
    return 0
  fi

  local p
  for p in "${PATHS[@]}"; do
    [ -d "$TC/$p" ] && git -C "$TC" add -A -- "$p/" 2>/dev/null
  done
  git -C "$TC" diff --cached --quiet && { log "noop: nothing staged"; return 0; }

  local hits
  hits="$(pii_hits)"
  if [ -n "$hits" ]; then
    git -C "$TC" reset -q -- "${PATHS[@]}" 2>/dev/null
    log "BLOCKED: unscrubbed email(s) in staged records: $(echo "$hits" | tr '\n' ' ')"
    printf 'team-context sync BLOCKED — scrub these before committing:\n%s\n' "$hits" >&2
    return 0
  fi

  local n msg
  n="$(git -C "$TC" diff --cached --numstat | wc -l | tr -d ' ')"
  msg="memory(auto): sync from $(hostname -s) $(date '+%F %H:%M') (${n} file(s))"
  git -C "$TC" commit -q -m "$msg" 2>/dev/null || { log "fail: commit"; return 0; }

  push_branch "$branch"
  return 0
}

case "$CMD" in
  sync)   sync ;;
  now)    sync force ;;
  pause)  : > "$PAUSE"; echo "auto-sync paused" ;;
  resume) rm -f "$PAUSE"; echo "auto-sync resumed" ;;
  status)
    echo "repo:   $TC"
    echo "branch: $(git -C "$TC" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '(detached)')"
    [ -f "$PAUSE" ] && echo "state:  PAUSED" || echo "state:  active"
    echo "pending:"; pending | sed 's/^/  /' | head -10
    [ -f "$LOG" ] && { echo "recent:"; tail -5 "$LOG" | sed 's/^/  /'; }
    ;;
  *) echo "usage: $0 [sync|now|pause|resume|status]" >&2; exit 2 ;;
esac
