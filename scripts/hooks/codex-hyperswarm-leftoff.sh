#!/usr/bin/env bash

# Codex SessionEnd adapter for the HyperSwarm claude-mem-session distiller.
#
# Gives Codex sessions the same "where coding left off" feed Claude Code has:
# on SessionEnd, distil THIS session's claude-mem summary through
# `hyperswarm capture --runtime claude_mem_session` (significance-gated, with
# the leftoff fallback) and push the staging store up to the canonical
# HyperSwarm store on Hostinger, where Jarvis ingestion makes it recallable by
# the Hermes/Telegram agents.
#
# Codex 0.145+ SessionEnd payloads carry the same fields Claude Code sends
# (session_id, cwd, hook_event_name), and codex thread ids ARE claude-mem's
# sdk_sessions.content_session_id, so the payload passes straight through to
# the distiller — no field mapping.
#
# Safety properties:
#   - RECURSION GUARD: the significance gate itself shells out to `codex exec`
#     with CODEX_NO_INTERACTIVE=1 in the child env. If that child fires
#     SessionEnd, this adapter sees the inherited variable and exits — the
#     gate can never trigger another gate.
#   - GATE-PROMPT SKIP: belt and braces for any other headless gate run — the
#     worker skips sessions whose recorded user_prompt is the gate preamble.
#   - DETACHED WORKER: the hook returns immediately; a nohup'd worker waits
#     (bounded) for claude-mem's async summary row before capturing, so codex
#     session close is never delayed and the summary race is closed.
#   - IDEMPOTENT: capture dedups on (runtime, memory_session_id); rsync push
#     only ships changed files. Re-running on the same session is a no-op.
#   - A session-end hook must never break the user's session: every path
#     exits 0.

set -uo pipefail

PY="$HOME/.hyperswarm/venv/bin/python"
DB="$HOME/.claude-mem/claude-mem.db"
LOG="${HS_CODEX_LOG:-/tmp/hs-codex-push.log}"
GATE_PREAMBLE='You are a significance gate'

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>&1 || true; }

# ---------------------------------------------------------------- worker
if [ "${1:-}" = "--worker" ]; then
  session_id="${2:-}"
  work_cwd="${3:-}"
  [ -n "$session_id" ] || exit 0
  log "=== worker start session=$session_id cwd=${work_cwd:-<none>} (pid $$) ==="

  if [ ! -x "$PY" ]; then
    log "FATAL: venv python missing at $PY — nothing captured"
    exit 0
  fi

  # Wait (bounded) for claude-mem's async pipeline to land BOTH the session
  # row and a summary for it. ~24 polls x 5s = 2 minutes max.
  ready=""
  for _ in $(seq 1 24); do
    ready="$(sqlite3 "file:$DB?mode=ro" "
      SELECT sk.user_prompt IS NOT NULL
      FROM sdk_sessions sk
      JOIN session_summaries ss ON ss.memory_session_id = sk.memory_session_id
      WHERE sk.content_session_id = '$session_id'
      LIMIT 1;" 2>/dev/null || true)"
    [ -n "$ready" ] && break
    sleep 5
  done
  if [ -z "$ready" ]; then
    log "no claude-mem summary appeared for $session_id within 2m — skipping capture, still pushing"
  else
    prompt_head="$(sqlite3 "file:$DB?mode=ro" "
      SELECT substr(COALESCE(user_prompt,''),1,40) FROM sdk_sessions
      WHERE content_session_id = '$session_id';" 2>/dev/null || true)"
    case "$prompt_head" in
      "$GATE_PREAMBLE"*)
        log "session $session_id is a significance-gate invocation — skipping"
        exit 0
        ;;
    esac

    # Scope tagging reads the git remote at cwd; fall back to \$HOME.
    cd "${work_cwd:-$HOME}" 2>/dev/null || cd "$HOME" || true

    if printf '{"session_id": "%s", "hook_event_name": "SessionEnd"}' "$session_id" \
         | "$PY" -m hyperswarm.cli capture --runtime claude_mem_session --verbose >>"$LOG" 2>&1; then
      log "capture: ok (entry written only if session qualified)"
    else
      log "capture: non-zero exit — continuing to push anyway"
    fi
  fi

  if "$PY" -m hyperswarm.cli push --verbose >>"$LOG" 2>&1; then
    log "push: ok"
  else
    log "push: non-zero exit"
  fi
  log "=== worker done ==="
  exit 0
fi

# ---------------------------------------------------------------- hook entry
# Recursion guard — see header.
[ -n "${CODEX_NO_INTERACTIVE:-}" ] && exit 0

input="$(cat 2>/dev/null || true)"

payload_field() {
  printf '%s' "$input" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get(sys.argv[1], "") or "")
except Exception:
    print("")' "$1" 2>/dev/null
}

session_id="$(payload_field session_id)"
[ -n "$session_id" ] || exit 0
work_cwd="$(payload_field cwd)"
[ -z "$work_cwd" ] && work_cwd="${CODEX_PROJECT_DIR:-}"

script_path="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
nohup "$script_path" --worker "$session_id" "$work_cwd" >/dev/null 2>&1 &
exit 0
