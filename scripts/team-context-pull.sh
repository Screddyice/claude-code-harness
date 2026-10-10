#!/usr/bin/env bash
# Pull team-context main without losing this Mac's personal Claude settings.
#
# team-context is $CLAUDE_CONFIG_DIR, so its tracked settings.json is also the
# user settings file. Personal values (model, plugins, autoMode, local hooks)
# live in the overlay below and are layered back on after every pull. A local
# edit that is in neither the tracked file nor the overlay stops the pull.
#
# Usage: team-context-pull.sh [apply]    apply = re-layer the overlay, no pull
set -euo pipefail
TC="${TEAM_CONTEXT_DIR:-$HOME/TeamNebula/team-context}"
OV="${TEAM_CONTEXT_OVERLAY:-$HOME/.claude/team-context-settings.overlay.json}"
[ -f "$OV" ] || { echo "missing overlay: $OV" >&2; exit 1; }
layer() {  # tracked settings on stdin + overlay -> stdout; hook lists are appended, not replaced
  jq --slurpfile o "$OV" '. as $b | $o[0] as $o
    | ($b * ($o | del(.hooks)))
    | .hooks = reduce (($o.hooks // {}) | to_entries[]) as $e ($b.hooks // {};
        .[$e.key] = ((.[$e.key] // []) + $e.value | unique_by(tojson)))'
}
expected="$(git -C "$TC" show HEAD:settings.json | layer | jq -S .)"
if [ "$(jq -S . "$TC/settings.json")" != "$expected" ]; then
  if [ "${1:-}" != "apply" ]; then
    echo "settings.json has edits that are in neither HEAD nor the overlay." >&2
    echo "Move them into $OV, or run '$0 apply' to discard them." >&2
    diff <(echo "$expected") <(jq -S . "$TC/settings.json") >&2 || true
    exit 1
  fi
fi
if [ "${1:-}" != "apply" ]; then
  git -C "$TC" checkout -q -- settings.json
  git -C "$TC" pull -q --ff-only
fi
git -C "$TC" show HEAD:settings.json | layer > "$TC/settings.json.tmp"
mv "$TC/settings.json.tmp" "$TC/settings.json"
echo "team-context at $(git -C "$TC" log --oneline -1); personal settings re-applied"
