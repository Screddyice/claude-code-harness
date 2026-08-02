#!/usr/bin/env bash
# Install / refresh Grok harness wiring into ~/.grok.
#
# Idempotent. Never enables [compat.claude] hooks or mcps — those import Claude
# Code's full hook chain (including the Ollama diff reviewer) and panicked this
# host on 2026-07-31. Grok uses native ~/.grok/hooks + ~/.grok/scripts only.
#
# claude-mem was fully removed from this machine and harness 2026-08-02.
# Do not re-add mem hooks, mcp-search, or skills-claude-mem.
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

# --- scripts (no claude-mem) ---
for name in load-projects-env.sh hyperswarm-leftoff.sh; do
  install_file "$REPO_ROOT/scripts/grok/$name" "$GROK_HOME/scripts/$name" 755
done

# --- hook JSON (no claude-mem) ---
for name in hyperswarm.json load-projects-env.json pr-tracking.json; do
  install_file "$REPO_ROOT/examples/grok/$name" "$GROK_HOME/hooks/$name"
done

# Ensure stale mem artifacts stay gone
if [[ "$CHECK_ONLY" -eq 0 ]]; then
  rm -f "$GROK_HOME/hooks/claude-mem.json" \
        "$GROK_HOME/scripts/claude-mem-hook.sh" \
        "$GROK_HOME/scripts/resolve-claude-mem.sh" \
        "$GROK_HOME/rules/claude-mem-context.md" 2>/dev/null || true
  rm -rf "$GROK_HOME/claude-mem-plugin" "$GROK_HOME/skills-claude-mem" 2>/dev/null || true
  ok "ensured claude-mem artifacts removed under $GROK_HOME"
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
    warn "$CFG has [compat.claude] mcps = true — keep false unless you know why"
  else
    ok "compat.claude mcps not enabled (safe)"
  fi
  if rg -q 'mcp-search|skills-claude-mem|claude-mem' "$CFG" 2>/dev/null; then
    warn "$CFG still mentions claude-mem / mcp-search / skills-claude-mem — remove those stanzas"
  else
    ok "config has no claude-mem wiring"
  fi
else
  warn "no $CFG yet — create one after first grok launch"
fi

# --- rules ---
mkdir -p "$GROK_HOME/rules"
if [[ -f "$REPO_ROOT/examples/grok/projects-workspace.md" ]]; then
  install_file "$REPO_ROOT/examples/grok/projects-workspace.md" "$GROK_HOME/rules/projects-workspace.md"
fi

echo
echo "Deliberately NOT installed on Grok:"
echo "  - claude-mem (removed 2026-08-02; do not re-add)"
echo "  - local-diff-review (Ollama) — GPU resident load caused kernel panics"
echo "  - [compat.claude] hooks/mcps — double-fires Claude's full hook chain"
echo
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "Check complete. Re-run without --check to sync files."
else
  echo "Install complete. Restart Grok (or open a new session) so hooks reload."
fi
