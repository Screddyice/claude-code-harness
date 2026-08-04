#!/usr/bin/env bash
#
# mem0-session-write.sh — Grok SessionEnd adapter that writes ONE session memory
# to Mem0 Platform, tagged with metadata.session_id.
#
# WHY THIS EXISTS
#   Every other host contributes memories: Claude Code and Codex run the mem0
#   plugin hooks, Hermes writes through its own provider. Grok reaches Mem0 over
#   MCP only, with no hook that writes a session_summary. Two consequences:
#     - Grok sessions were invisible to recall on every other host.
#     - HyperSwarm's mem0_session distiller matches on metadata.session_id, so
#       a Grok session could never produce a corpus entry. That limitation was
#       recorded in claude-code-harness PR #18 and left open.
#
# SOURCE OF TRUTH
#   ~/.grok/sessions/<url-encoded cwd>/prompt_history.jsonl holds what the user
#   actually typed, keyed by session_id. The per-session chat_history.jsonl is
#   NOT used: its user turns are wrapped blocks (<user_info>, <user_query>) that
#   need unwrapping, while prompt_history is already clean.
#   <session dir>/summary.json contributes Grok's own generated title.
#
# SAFETY
#   Detached worker so session close is never delayed. Always exits 0 -- a
#   SessionEnd hook must never break the user's shell. Writes only; never reads
#   Mem0, so it cannot consume the retrieval quota that mem0-local exists to
#   protect (Starter allows 50,000 adds/month against 5,000 retrievals).
#
set -uo pipefail

LOG="${GROK_MEM0_LOG:-/tmp/grok-mem0-write.log}"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>&1 || true; }

# Hook envs are thin; the key lives in ~/projects/.env.
if [ -z "${MEM0_API_KEY:-}" ] && [ -f "$HOME/projects/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  . <(grep -E '^MEM0_API_KEY=' "$HOME/projects/.env" 2>/dev/null || true)
  set +a
fi

PY="${GROK_MEM0_PYTHON:-$HOME/.local/share/mem0-venv/bin/python}"
[ -x "$PY" ] || PY=/usr/bin/python3

# ---------------------------------------------------------------- worker
if [ "${1:-}" = "--worker" ]; then
  session_id="${2:-}"
  work_cwd="${3:-$HOME}"
  [ -n "$session_id" ] || exit 0
  [ -n "${MEM0_API_KEY:-}" ] || { log "no MEM0_API_KEY; skipping $session_id"; exit 0; }
  log "=== worker start session=$session_id cwd=$work_cwd ==="

  MEM0_SESSION_ID="$session_id" MEM0_WORK_CWD="$work_cwd" "$PY" - <<'PYEOF' >>"$LOG" 2>&1
import json, os, sys, urllib.parse, urllib.request
from pathlib import Path

sid = os.environ["MEM0_SESSION_ID"]
cwd = os.environ.get("MEM0_WORK_CWD") or str(Path.home())
key = os.environ.get("MEM0_API_KEY", "")
user_id = os.environ.get("MEM0_USER_ID", "screddy")
root = Path(os.environ.get("GROK_HOME", Path.home() / ".grok")) / "sessions"

# Grok encodes the cwd into the directory name.
enc = urllib.parse.quote(cwd, safe="")
sess_dir = root / enc / sid

title = ""
summ = sess_dir / "summary.json"
if summ.is_file():
    try:
        s = json.loads(summ.read_text())
        title = (s.get("generated_title") or s.get("session_summary") or "").strip()
    except Exception:
        pass

prompts, seen = [], set()
ph = root / enc / "prompt_history.jsonl"
if ph.is_file():
    for line in ph.read_text(errors="replace").splitlines():
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("session_id") != sid or d.get("is_bash"):
            continue
        p = " ".join((d.get("prompt") or "").split())
        if len(p) < 12 or p in seen:
            continue
        seen.add(p)
        prompts.append(p[:300])

if not prompts and not title:
    print(f"nothing to record for {sid}")
    raise SystemExit(0)

# Name the repo/org so the memory is filterable later, matching how other hosts
# tag scope. Metadata carries it; the body stays human-readable.
repo = ""
try:
    import subprocess
    repo = subprocess.run(["git", "-C", cwd, "remote", "get-url", "origin"],
                          capture_output=True, text=True, timeout=8).stdout.strip()
except Exception:
    pass

body = [f"Grok session: {title}" if title else "Grok session"]
body.append(f"Working directory: {cwd}" + (f" (origin {repo})" if repo else ""))
if prompts:
    body.append("What the user asked, in order:")
    body.extend(f"- {p}" for p in prompts[:25])
text = "\n".join(body)[:6000]

payload = {
    "messages": [{"role": "user", "content": text}],
    "user_id": user_id,
    "app_id": "projects",
    "metadata": {
        "type": "session_summary",
        "source": "grok",
        "session_id": sid,
        "cwd": cwd,
    },
}
req = urllib.request.Request(
    "https://api.mem0.ai/v1/memories/",
    data=json.dumps(payload).encode(),
    headers={"Authorization": f"Token {key}", "Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=45) as r:
        out = r.read().decode()[:200]
    print(f"wrote session memory for {sid} ({len(prompts)} prompt(s)): {out}")
except Exception as e:
    print(f"write failed for {sid}: {e}")
PYEOF

  log "=== worker done ==="
  exit 0
fi

# ---------------------------------------------------------------- hook entry
# Recursion guards: the same markers the other harness hooks honour, so a
# headless child (a gate, a codex exec) cannot trigger another session write.
[ -n "${CODEX_NO_INTERACTIVE:-}" ] && exit 0
[ -n "${GROK_MEM0_NO_RECURSE:-}" ] && exit 0

input="$(cat 2>/dev/null || true)"

field() {
  printf '%s' "$input" | "$PY" -c '
import json, re, sys
key = sys.argv[1]
try:
    j = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
snake = re.sub(r"([A-Z])", r"_\1", key).lower().lstrip("_")
parts = key.split("_")
camel = parts[0] + "".join(p.title() for p in parts[1:])
for k in (key, snake, camel):
    v = j.get(k)
    if v not in (None, ""):
        print(v); raise SystemExit
print("")
' "$1" 2>/dev/null
}

session_id="$(field sessionId)"
[ -n "$session_id" ] || session_id="${GROK_SESSION_ID:-}"
[ -n "$session_id" ] || exit 0

work_cwd="$(field cwd)"
[ -z "$work_cwd" ] && work_cwd="$(field workspaceRoot)"
[ -z "$work_cwd" ] && work_cwd="${GROK_WORKSPACE_ROOT:-$PWD}"

script_path="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
nohup env GROK_MEM0_NO_RECURSE=1 "$script_path" --worker "$session_id" "$work_cwd" \
  >/dev/null 2>&1 &
exit 0
