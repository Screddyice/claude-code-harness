#!/bin/bash
# Coverage for the claude-harness PreToolUse guard patch. Two halves: the patched
# guard reaches the right verdicts, and harness-guard-patch.sh detects and repairs
# a copy that a plugin sync reverted.
#
# Nothing here runs the commands under test. Only the hook ever sees them, and it
# works on a throwaway project directory.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PATCHER="$ROOT/scripts/hooks/harness-guard-patch.sh"
BEFORE="$ROOT/scripts/hooks/harness-guard-patch.before"
AFTER="$ROOT/scripts/hooks/harness-guard-patch.after"

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/harness-guard.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

# A copy of the real hook, patched, standing in for an installed plugin.
PLUGIN="$FIXTURE/plugins/marketplaces/claude-harness/plugins/claude-harness/hooks"
mkdir -p "$PLUGIN"
installed=$(find "$HOME/.claude/plugins" -path '*claude-harness*/hooks/pre-tool-use' -type f 2>/dev/null | head -1)
if [ -z "$installed" ]; then
  printf 'skip: the claude-harness plugin is not installed here\n'
  exit 0
fi
cp "$installed" "$PLUGIN/pre-tool-use"

PROJ="$FIXTURE/project"
mkdir -p "$PROJ/.claude-harness"

verdict() {
  local out
  # An allowing hook prints nothing at all, so empty output is the allow signal.
  out=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" |
        CLAUDE_PROJECT_DIR="$PROJ" bash "$PLUGIN/pre-tool-use" 2>/dev/null)
  [ -n "$out" ] || { echo allow; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow
}

check() {
  local want=$1 cmd=$2 label=$3 got
  got=$(verdict "$cmd")
  if [ "$got" = "$want" ]; then pass "$got  $label"; else fail "$label" "want=$want got=$got"; fi
}

# Ensure the copy under test is patched before asserting the new behavior.
CLAUDE_PLUGIN_ROOT_DIR="$FIXTURE/plugins" bash "$PATCHER" >/dev/null 2>&1

# --- what the rule must still stop ------------------------------------------

check deny  'rm -rf .claude-harness'                         'a bare recursive delete'
check deny  'cd /tmp && rm -rf .claude-harness'              'a recursive delete after a separator'
check deny  'sudo rm -rf ~/.claude-harness'                  'a recursive delete via sudo'
check deny  'if rm -rf .claude-harness; then echo gone; fi'  'a recursive delete after a shell keyword'
check deny  'sudo -u root rm -rf .claude-harness'            'a recursive delete via sudo with options'
check deny  'xargs -0 rm -rf .claude-harness'                'a recursive delete via xargs with options'
check deny  'rm -r .claude-harness/memory'                   'a recursive delete of a subdirectory'
# Anchoring the rule to command position loses `git rm`, so it gets its own rule.
check deny  'git rm -r .claude-harness'                      'git rm without --cached, which deletes from the tree'

# --- what it wrongly stopped before -----------------------------------------

check allow 'git rm -r --cached .claude-harness'             'git rm --cached, which only drops index entries'
check allow 'git rm -q --cached .claude-harness/config.json' 'git rm --cached on a single path'
check allow '# guard against rm -rf .claude-harness'         'the phrase inside a comment'
# A markdown code span is not command position. Treating it as one blocked every
# file that documented this rule, including this repo's README.
check allow 'echo "| `rm -rf .claude-harness` | deny |" >> README.md' 'the phrase inside a markdown code span'
check allow "cat > /tmp/s.sh <<'EOF'
# blocks rm -rf .claude-harness
EOF"                                                         'the phrase inside a heredoc'

# --- the plugin's other rules must survive the edit -------------------------

check deny  'git push --force origin main'                   'a force push'
check deny  'git reset --hard HEAD~1'                        'a hard reset'
check deny  'git clean -fd'                                  'a git clean'
check deny  'git push origin main'                           'a direct push to main'
check allow 'git status'                                     'an ordinary command'
check allow 'rm -rf /tmp/scratch'                            'a recursive delete of something else'

# --- the reinstaller ---------------------------------------------------------

CLAUDE_PLUGIN_ROOT_DIR="$FIXTURE/plugins" bash "$PATCHER" --check >/dev/null 2>&1
[ $? -eq 0 ] && pass "--check passes on a patched copy" || fail "--check passes on a patched copy"

python3 - "$PLUGIN/pre-tool-use" "$BEFORE" "$AFTER" <<'PY'
import pathlib, sys
hook, before, after = (pathlib.Path(p) for p in sys.argv[1:4])
hook.write_text(hook.read_text().replace(after.read_text(), before.read_text(), 1))
PY

CLAUDE_PLUGIN_ROOT_DIR="$FIXTURE/plugins" bash "$PATCHER" --check >/dev/null 2>&1
[ $? -eq 1 ] && pass "--check fails on a copy a plugin sync reverted" || fail "--check fails on a reverted copy"

got=$(verdict 'git rm -r --cached .claude-harness')
[ "$got" = deny ] && pass "deny  the reverted copy blocks git rm --cached again" ||
  fail "the reverted copy blocks git rm --cached again" "got=$got"

CLAUDE_PLUGIN_ROOT_DIR="$FIXTURE/plugins" bash "$PATCHER" >/dev/null 2>&1
got=$(verdict 'git rm -r --cached .claude-harness')
[ "$got" = allow ] && pass "allow the reinstaller repairs it" || fail "the reinstaller repairs it" "got=$got"

# Apply mode is a SessionStart hook and must never fail a session, even with
# nothing to patch and no plugin directory to look at.
CLAUDE_PLUGIN_ROOT_DIR="$FIXTURE/nonexistent" bash "$PATCHER" >/dev/null 2>&1
[ $? -eq 0 ] && pass "apply mode exits 0 with no plugin installed" || fail "apply mode exits 0 with no plugin installed"

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'all harness-guard checks passed' || echo "$fails harness-guard check(s) failed")"
exit $(( fails > 0 ))
