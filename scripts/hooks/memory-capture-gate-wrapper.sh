#!/bin/bash
# Stable local wrapper for the ClaudeMem capture boundary.
# The implementation is kept beside this hook so it survives repo changes.
set -uo pipefail
FALLBACK="$HOME/.claude/scripts/memory-capture-gate.impl.sh"
[ -x "$FALLBACK" ] && exec "$FALLBACK" "$@"
echo '{"systemMessage":"memory-capture-gate: no implementation found; TMN/R2H repos are NOT being excluded from claude-mem."}'
exit 0
