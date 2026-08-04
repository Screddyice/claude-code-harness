#!/usr/bin/env bash
#
# Grok SessionEnd adapter for HyperSwarm (mem0-session distiller).
#
# Same path Claude Code and Codex use:
#   1. Let Mem0 settle after session close
#   2. Distil via `hyperswarm capture --runtime mem0_session` (significance-gated)
#   3. Push Mac staging → Hostinger canonical store
#
# Grok hook payloads use camelCase (sessionId); capture expects session_id.
# Detached worker so session close is never delayed. Always exits 0.
#
# Before 2026-08-02 this targeted --runtime claude_mem_session and gated on a
# summary row in ~/.claude-mem/claude-mem.db. claude-mem was retired and that
# database deleted, so the gate could never pass and Grok captured nothing.
#
# CAVEAT: Grok reaches Mem0 through MCP only, with no hook that writes a
# session_summary on its own. Mem0SessionSource matches on
# metadata.session_id, so this captures only when the Grok session actually
# wrote session-tagged memories. Codex has the mem0 plugin hooks and does.
#
set -uo pipefail

PY="$HOME/.hyperswarm/venv/bin/python"
LOG="${HS_GROK_LOG:-/tmp/hs-grok-push.log}"

# Hook envs are thin; capture needs the Mem0 key.
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
  log "=== grok worker start session=$session_id cwd=${work_cwd:-<none>} (pid $$) ==="

  if [ ! -x "$PY" ]; then
    log "FATAL: venv python missing at $PY — nothing captured"
    exit 0
  fi

  # Let Mem0 settle after session close before the distiller reads it.
  sleep 5

  cd "${work_cwd:-$HOME}" 2>/dev/null || cd "$HOME" || true

  payload=$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionEnd","runtime":"grok"}' \
    "$(printf '%s' "$session_id" | sed 's/"/\\"/g')" \
    "$(printf '%s' "${work_cwd:-}" | sed 's/"/\\"/g')")

  if printf '%s' "$payload" | "$PY" -m hyperswarm.cli capture \
        --runtime mem0_session --verbose >>"$LOG" 2>&1; then
    log "capture: ok (entry written only if session qualified)"
  else
    log "capture: non-zero exit — continuing to push"
  fi

  if "$PY" -m hyperswarm.cli push --verbose >>"$LOG" 2>&1; then
    log "push: ok"
  else
    log "push: non-zero exit"
  fi
  log "=== grok worker done ==="
  exit 0
fi

# ---------------------------------------------------------------- hook entry
# Skip if a nested significance-gate / codex-exec re-entered us.
[ -n "${CODEX_NO_INTERACTIVE:-}" ] && exit 0
[ -n "${HS_GROK_NO_RECURSE:-}" ] && exit 0

input="$(cat 2>/dev/null || true)"

payload_field() {
  # Accept camelCase (Grok) and snake_case (Claude/Codex).
  printf '%s' "$input" | python3 -c 'import json,sys
keys=[sys.argv[1]]
# also try snake_case conversion of camelCase
import re
k=sys.argv[1]
snake=re.sub(r"([A-Z])", r"_\1", k).lower().lstrip("_")
if snake!=k: keys.append(snake)
# and camel from snake
parts=k.split("_")
if len(parts)>1:
    camel=parts[0]+"".join(p.title() for p in parts[1:])
    keys.append(camel)
try:
    j=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
for key in keys:
    v=j.get(key)
    if v is not None and str(v)!="":
        print(v); raise SystemExit
print(j.get("sessionId") or j.get("session_id") or "")
' "$1" 2>/dev/null
}

session_id="$(payload_field sessionId)"
[ -n "$session_id" ] || session_id="${GROK_SESSION_ID:-}"
[ -n "$session_id" ] || exit 0

work_cwd="$(payload_field cwd)"
[ -z "$work_cwd" ] && work_cwd="$(payload_field workspaceRoot)"
[ -z "$work_cwd" ] && work_cwd="${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}"

script_path="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
nohup env HS_GROK_NO_RECURSE=1 "$script_path" --worker "$session_id" "$work_cwd" \
  >/dev/null 2>&1 &
exit 0
