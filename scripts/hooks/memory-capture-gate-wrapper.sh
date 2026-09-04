#!/bin/bash
# Compat wrapper: the implementation lives in claude-code-harness. Edit there.
#
# It falls back to a copy because the harness checkout is a working tree that
# moves between branches, and the hook is registered against this fixed path.
# On 2026-09-04 the checkout sat on a branch without the script for weeks: the
# hook exec'd a file that did not exist, exited non-zero, and the gate silently
# never ran — so TMN sessions were captured the whole time. A gate that fails
# open is worse than no gate, because it looks installed.
set -uo pipefail
IMPL="$HOME/projects/SRC/claude-code-harness/scripts/hooks/memory-capture-gate.sh"
FALLBACK="$HOME/.claude/scripts/memory-capture-gate.impl.sh"
if [ -x "$IMPL" ]; then
  # Keep the fallback current whenever the real one is reachable.
  cmp -s "$IMPL" "$FALLBACK" 2>/dev/null || cp "$IMPL" "$FALLBACK" 2>/dev/null
  exec "$IMPL" "$@"
fi
[ -x "$FALLBACK" ] && exec "$FALLBACK" "$@"
echo '{"systemMessage":"memory-capture-gate: no implementation found; TMN/R2H repos are NOT being excluded from claude-mem."}'
exit 0
