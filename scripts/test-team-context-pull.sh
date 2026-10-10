#!/usr/bin/env bash
# shellcheck disable=SC2016  # each check is single-quoted on purpose and run later by eval
# team-context-pull.sh layers personal settings over team-context's tracked
# settings.json, so every `claude` launch starts in bypassPermissions mode and a
# pull of the shared repo never drops or conflicts with that choice.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL="$HERE/team-context-pull.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1" >&2; fi; }
g() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T "$@"; }

g init -q --bare "$ROOT/origin.git"
g clone -q "$ROOT/origin.git" "$ROOT/tc" 2>/dev/null
printf '{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"team"}]}]}}\n' > "$ROOT/tc/settings.json"
g -C "$ROOT/tc" add settings.json && g -C "$ROOT/tc" commit -qm base && g -C "$ROOT/tc" push -q origin HEAD 2>/dev/null
cp "$HERE/../examples/team-context-settings.overlay.json" "$ROOT/overlay.json"
export TEAM_CONTEXT_DIR="$ROOT/tc" TEAM_CONTEXT_OVERLAY="$ROOT/overlay.json"

"$PULL" apply >/dev/null 2>&1
ok "apply sets bypassPermissions" '[ "$(jq -r .permissions.defaultMode "$ROOT/tc/settings.json")" = bypassPermissions ]'
ok "apply skips the startup confirmation" '[ "$(jq -r .skipDangerousModePermissionPrompt "$ROOT/tc/settings.json")" = true ]'
ok "apply keeps tracked hooks" '[ "$(jq -r ".hooks.SessionStart[0].hooks[0].command" "$ROOT/tc/settings.json")" = team ]'

# an upstream change to settings.json lands without losing the default mode
g clone -q "$ROOT/origin.git" "$ROOT/other" 2>/dev/null
jq '.model = "sonnet"' "$ROOT/other/settings.json" > "$ROOT/s" && mv "$ROOT/s" "$ROOT/other/settings.json"
g -C "$ROOT/other" commit -qam upstream && g -C "$ROOT/other" push -q origin HEAD 2>/dev/null
"$PULL" >/dev/null 2>&1
ok "pull brings the upstream change" '[ "$(jq -r .model "$ROOT/tc/settings.json")" = sonnet ]'
ok "pull keeps bypassPermissions" '[ "$(jq -r .permissions.defaultMode "$ROOT/tc/settings.json")" = bypassPermissions ]'

# a local edit that is in neither file stops the pull instead of being lost
jq '.theme = "light"' "$ROOT/tc/settings.json" > "$ROOT/s" && mv "$ROOT/s" "$ROOT/tc/settings.json"
ok "stray local edit blocks the pull" '! "$PULL" >/dev/null 2>&1'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
