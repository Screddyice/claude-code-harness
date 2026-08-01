#!/usr/bin/env bash
# Install / refresh Grok harness + claude-mem wiring into ~/.grok.
#
# Idempotent. Never enables [compat.claude] hooks or mcps — those import Claude
# Code's full hook chain (including the Ollama diff reviewer) and panicked this
# host on 2026-07-31. Grok uses native ~/.grok/hooks + ~/.grok/scripts only.
#
# Usage:
#   scripts/install-grok-harness.sh           # install/update
#   scripts/install-grok-harness.sh --check   # report status, no writes
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GROK_HOME="${GROK_HOME:-$HOME/.grok}"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

ok() { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '  ✗ %s\n' "$*" >&2; }

install_file() {
  local src=$1 dest=$2 mode=${3:-}
  if [[ ! -f "$src" ]]; then
    fail "missing source: $src"
    return 1
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
      ok "up to date: $dest"
    elif [[ -f "$dest" ]]; then
      warn "differs from repo: $dest (run without --check to sync)"
    else
      warn "missing: $dest"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  [[ -n "$mode" ]] && chmod "$mode" "$dest"
  ok "installed $dest"
}

echo "Grok harness install (repo=$REPO_ROOT, home=$GROK_HOME)"

# --- scripts ---
for name in claude-mem-hook.sh resolve-claude-mem.sh load-projects-env.sh hyperswarm-leftoff.sh; do
  install_file "$REPO_ROOT/scripts/grok/$name" "$GROK_HOME/scripts/$name" 755
done

# --- hook JSON ---
for name in claude-mem.json hyperswarm.json load-projects-env.json pr-tracking.json; do
  install_file "$REPO_ROOT/examples/grok/$name" "$GROK_HOME/hooks/$name"
done

# --- claude-mem plugin symlink + skills ---
if [[ "$CHECK_ONLY" -eq 0 ]]; then
  RESOLVE="$GROK_HOME/scripts/resolve-claude-mem.sh"
  if ROOT=$("$RESOLVE" 2>/dev/null); then
    ln -sfn "$ROOT" "$GROK_HOME/claude-mem-plugin"
    ln -sfn "$ROOT/skills" "$GROK_HOME/skills-claude-mem"
    ok "claude-mem plugin → $ROOT"
    ok "skills-claude-mem → $ROOT/skills"
  else
    warn "claude-mem install not found; symlink skipped (install thedotmack/claude-mem in Claude Code first)"
  fi
else
  if [[ -L "$GROK_HOME/claude-mem-plugin" || -d "$GROK_HOME/claude-mem-plugin" ]]; then
    ok "claude-mem-plugin present"
  else
    warn "claude-mem-plugin missing"
  fi
fi

# --- config.toml safety checks (never auto-rewrite secrets / personal prefs) ---
CFG="$GROK_HOME/config.toml"
if [[ -f "$CFG" ]]; then
  if rg -q '^\s*hooks\s*=\s*true' "$CFG" 2>/dev/null; then
    fail "$CFG has [compat.claude] hooks = true — DISABLE IT. That imports Claude's Ollama diff reviewer into Grok and has panicked this host."
  else
    ok "compat.claude hooks not enabled (safe)"
  fi
  if rg -q '^\s*mcps\s*=\s*true' "$CFG" 2>/dev/null; then
    warn "$CFG has [compat.claude] mcps = true — prefer native [mcp_servers.mcp-search] only"
  else
    ok "compat.claude mcps not enabled (safe)"
  fi
  if rg -q 'mcp-search|mcp_servers\.mcp-search' "$CFG" 2>/dev/null; then
    ok "mcp-search server configured"
  else
    warn "no mcp-search in config.toml — add [mcp_servers.mcp-search] from README (Grok section)"
  fi
  if rg -q 'skills-claude-mem' "$CFG" 2>/dev/null; then
    ok "skills path includes skills-claude-mem"
  else
    warn "add skills-claude-mem to [skills].paths in config.toml"
  fi
else
  warn "no $CFG yet — create one after first grok launch"
fi

# --- worker health ---
PORT="${CLAUDE_MEM_WORKER_PORT:-}"
if [[ -z "$PORT" && -f "$HOME/.claude-mem/settings.json" ]]; then
  PORT=$(node -e "try{const s=require(require('path').join(require('os').homedir(),'.claude-mem','settings.json'));process.stdout.write(String(s.CLAUDE_MEM_WORKER_PORT||''))}catch{}" 2>/dev/null || true)
fi
PORT="${PORT:-37701}"
if curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
  ok "claude-mem worker healthy on :$PORT"
else
  warn "claude-mem worker not responding on :$PORT (first Grok SessionStart starts it)"
fi

# --- what we deliberately do NOT install ---
echo
echo "Deliberately NOT installed on Grok:"
echo "  - local-diff-review (Ollama) — GPU resident load caused kernel panics"
echo "  - [compat.claude] hooks/mcps — double-fires Claude's full hook chain"
echo "  - claude-mem marketplace plugin inside Grok — native hooks + MCP instead"
echo
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "Check complete. Re-run without --check to sync files."
else
  echo "Install complete. Restart Grok (or open a new session) so hooks reload."
  echo "Verify: /hooks  and  curl -s http://127.0.0.1:${PORT}/api/health"
fi
