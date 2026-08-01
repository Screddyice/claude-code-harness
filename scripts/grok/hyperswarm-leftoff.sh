#!/usr/bin/env bash
#
# Grok SessionEnd adapter for HyperSwarm (claude-mem-session distiller).
#
# Same path Claude Code and Codex use:
#   1. Wait (bounded) for claude-mem to land a session summary for THIS session
#   2. Distil via `hyperswarm capture --runtime claude_mem_session` (significance-gated)
#   3. Push Mac staging → Hostinger canonical store
#
# Grok hook payloads use camelCase (sessionId); capture expects session_id.
# Detached worker so session close is never delayed. Always exits 0.
#
set -uo pipefail

PY="$HOME/.hyperswarm/venv/bin/python"
DB="$HOME/.claude-mem/claude-mem.db"
LOG="${HS_GROK_LOG:-/tmp/hs-grok-push.log}"
GATE_PREAMBLE='You are a significance gate'

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

  # Wait for claude-mem async summary (~24 × 5s = 2 min).
  ready=""
  for _ in $(seq 1 24); do
    ready="$(sqlite3 "file:$DB?mode=ro" "
      SELECT sk.user_prompt IS NOT NULL
      FROM sdk_sessions sk
      JOIN session_summaries ss ON ss.memory_session_id = sk.memory_session_id
      WHERE sk.content_session_id = '$(printf '%s' "$session_id" | sed "s/'/''/g")'
      LIMIT 1;" 2>/dev/null || true)"
    [ -n "$ready" ] && break
    sleep 5
  done
  if [ -z "$ready" ]; then
    log "no claude-mem summary for $session_id within 2m — skip capture, still push"
  else
    prompt_head="$(sqlite3 "file:$DB?mode=ro" "
      SELECT substr(COALESCE(user_prompt,''),1,40) FROM sdk_sessions
      WHERE content_session_id = '$(printf '%s' "$session_id" | sed "s/'/''/g")';" 2>/dev/null || true)"
    case "$prompt_head" in
      "$GATE_PREAMBLE"*)
        log "session $session_id is a significance-gate invocation — skipping"
        exit 0
        ;;
    esac

    cd "${work_cwd:-$HOME}" 2>/dev/null || cd "$HOME" || true

    payload=$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionEnd","runtime":"grok"}' \
      "$(printf '%s' "$session_id" | sed 's/"/\\"/g')" \
      "$(printf '%s' "${work_cwd:-}" | sed 's/"/\\"/g')")

    if printf '%s' "$payload" | "$PY" -m hyperswarm.cli capture \
          --runtime claude_mem_session --verbose >>"$LOG" 2>&1; then
      log "capture: ok (entry written only if session qualified)"
    else
      log "capture: non-zero exit — continuing to push"
    fi
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
