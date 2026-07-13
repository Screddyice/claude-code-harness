#!/usr/bin/env bash
# Adapt the existing read-only local reviewer to Codex's Stop-hook JSON contract.

set -u

# Consume the event payload so a future reviewer can use it without changing this hook.
cat >/dev/null 2>&1 || true

reviewer="${CODEX_LOCAL_REVIEWER:-$HOME/.claude/scripts/local-diff-review.sh}"
[ -x "$reviewer" ] || exit 0

set +e
findings="$($reviewer 2>/dev/null)"
status=$?
set -e

[ "$status" -eq 2 ] || exit 0
[ -n "$findings" ] || exit 0

FINDINGS="$findings" python3 - <<'PY'
import json
import os

findings = os.environ["FINDINGS"]
print(json.dumps({
    "continue": False,
    "stopReason": "Local diff review found possible defects that need verification.",
    "systemMessage": (
        "A small local model reviewed the current branch diff. Verify each finding "
        "against the code, fix confirmed defects, and ignore false positives:\n\n" + findings
    ),
}))
PY
