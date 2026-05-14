#!/bin/bash
# Auto-initialize claude-harness in any git repo when a Claude Code session starts.
# Wired via SessionStart hook in ~/.claude/settings.json.
#
# This wraps the upstream claude-harness plugin's setup.sh so that any git repo
# you open in Claude Code automatically gets a .claude-harness/ directory if
# one doesn't already exist.
#
# Customize the SKIP_PATTERNS section below for any orgs/repos that should be
# excluded from auto-init (e.g. high-stakes client repos where you want every
# change to be human-reviewed).
#
# Output is suppressed; errors are written to ~/.claude/scripts/auto-init-harness.log
# This script never blocks the session: it always exits 0.

set +e

LOG="$HOME/.claude/scripts/auto-init-harness.log"

# Pinned path to the upstream claude-harness plugin's setup.sh.
# Adjust the version segment after `claude-harness/` to match your installed version,
# or rely on the glob fallback below to find it dynamically.
PLUGIN_SETUP="$HOME/.claude/plugins/cache/claude-harness/claude-harness/setup.sh"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }

# Resolve target dir from Claude Code env, fall back to PWD
TARGET="${CLAUDE_PROJECT_DIR:-$PWD}"

[ -z "$TARGET" ] && exit 0
[ -d "$TARGET" ] || exit 0

cd "$TARGET" 2>/dev/null || exit 0

# Skip if not a git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

# Use repo root, not arbitrary subdir
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$REPO_ROOT" ] && exit 0
cd "$REPO_ROOT" || exit 0

# Already initialized — nothing to do
[ -d "$REPO_ROOT/.claude-harness" ] && exit 0

# Lockdown patterns — customize for any orgs/repos that should be excluded
NAME_LOWER=$(basename "$REPO_ROOT" | tr '[:upper:]' '[:lower:]')
REMOTE_LOWER=$(git remote get-url origin 2>/dev/null | tr '[:upper:]' '[:lower:]')

# Example: skip if repo name contains "client-x" AND remote is under your org
# if [[ "$NAME_LOWER" == *client-x* && "$REMOTE_LOWER" == *your-org* ]]; then
#     log "lockdown: skipped $REPO_ROOT"
#     exit 0
# fi

# Resolve a working setup.sh — prefer pinned path, fall back to glob
if [ ! -x "$PLUGIN_SETUP" ] && [ ! -f "$PLUGIN_SETUP" ]; then
    PLUGIN_SETUP=$(find "$HOME/.claude/plugins/cache/claude-harness" -name setup.sh -type f 2>/dev/null | head -1)
fi
if [ -z "$PLUGIN_SETUP" ] || [ ! -f "$PLUGIN_SETUP" ]; then
    log "ERROR: setup.sh not found under ~/.claude/plugins/cache/claude-harness for $REPO_ROOT"
    exit 0
fi

# Run setup.sh quietly. Idempotent.
if bash "$PLUGIN_SETUP" >/dev/null 2>&1; then
    log "auto-initialized harness in $REPO_ROOT"
else
    log "WARN: setup.sh exited non-zero in $REPO_ROOT"
fi

exit 0
