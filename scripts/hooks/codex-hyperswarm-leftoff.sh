#!/usr/bin/env bash

# Codex SessionEnd adapter for the HyperSwarm mem0-session distiller.
#
# Gives Codex sessions the same "where coding left off" feed Claude Code has:
# on SessionEnd, distil THIS session's Mem0 memories through
# `hyperswarm capture --runtime mem0_session` (significance-gated, with
# the leftoff fallback) and push the staging store up to the canonical
# HyperSwarm store on Hostinger, where Jarvis ingestion makes it recallable by
# the Hermes/Telegram agents.
#
# Codex 0.145+ SessionEnd payloads carry the same fields Claude Code sends
# (session_id, cwd, hook_event_name), and Mem0SessionSource.capture() reads
# exactly those, matching memories on metadata.session_id — so the payload
# passes straight through to the distiller with no field mapping.
#
# Before 2026-08-02 this adapter targeted --runtime claude_mem_session and
# gated on a summary row in ~/.claude-mem/claude-mem.db. claude-mem was
# retired, that database was deleted, and config.toml dropped the source, so
# the gate could never pass and Codex captured nothing. Both are gone now.
#
# Safety properties:
#   - RECURSION GUARD: the significance gate itself shells out to `codex exec`
#     with CODEX_NO_INTERACTIVE=1 in the child env. If that child fires
#     SessionEnd, this adapter sees the inherited variable and exits — the
#     gate can never trigger another gate.
#   - DETACHED WORKER: the hook returns immediately; a nohup'd worker lets Mem0
#     settle before capturing, so codex session close is never delayed.
#   - SAFE NO-OP: capture writes nothing when Mem0 holds no memories for the
#     session, so no local gate is needed to decide whether it is worth running.
#   - IDEMPOTENT: capture dedups on (runtime, memory_session_id); rsync push
#     only ships changed files. Re-running on the same session is a no-op.
#   - A session-end hook must never break the user's session: every path
#     exits 0.

set -uo pipefail

PY="$HOME/.hyperswarm/venv/bin/python"
LOG="${HS_CODEX_LOG:-/tmp/hs-codex-push.log}"

# Hook envs are thin; the resolver and capture both need the Mem0 key.
if [ -z "${MEM0_API_KEY:-}" ] && [ -f "$HOME/projects/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  . <(grep -E '^MEM0_API_KEY=' "$HOME/projects/.env" 2>/dev/null || true)
  set +a
fi

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

  # The mem0 plugin writes this session's memories asynchronously on SessionEnd.
  # Let them land before asking the distiller to read them.
  sleep 5

  # Scope tagging reads the git remote at cwd; fall back to $HOME.
  cd "${work_cwd:-$HOME}" 2>/dev/null || cd "$HOME" || true

  if printf '{"session_id": "%s", "cwd": "%s", "hook_event_name": "SessionEnd"}' \
       "$session_id" "$(printf '%s' "${work_cwd:-}" | sed 's/"/\\"/g')" \
       | "$PY" -m hyperswarm.cli capture --runtime mem0_session --verbose >>"$LOG" 2>&1; then
    log "capture: ok (entry written only if session qualified)"
  else
    log "capture: non-zero exit — continuing to push anyway"
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
