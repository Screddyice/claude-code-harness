#!/usr/bin/env bash

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
hooks="$repo_root/scripts/hooks"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/runtime"
git -C "$tmp/repo" init -q -b main
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid \
  commit --allow-empty -qm "initial"
git -C "$tmp/repo" remote add origin https://github.com/example/repo.git
git -C "$tmp/repo" switch -qc feat/test
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid \
  commit --allow-empty -qm "change"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${MOCK_GH_MODE:-missing}" = "error" ]; then exit 1; fi' \
  'if [ "${MOCK_GH_MODE:-missing}" = "present" ]; then echo 1; else echo 0; fi' \
  > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

payload="$(printf '{\"cwd\":\"%s\"}' "$tmp/repo")"

claude_output="$(printf '%s' "$payload" | PATH="$tmp/bin:$PATH" \
  "$hooks/enforce-pr-claude.sh")"
printf '%s' "$claude_output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["decision"] == "block"
assert "feat/test" in result["reason"]
'

codex_output="$(printf '%s' "$payload" | PATH="$tmp/bin:$PATH" TMPDIR="$tmp/runtime" \
  "$hooks/enforce-pr-codex.sh")"
printf '%s' "$codex_output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["continue"] is False
assert "feat/test" in result["systemMessage"]
'

claude_silent="$(printf '%s' "$payload" | PATH="$tmp/bin:$PATH" MOCK_GH_MODE=present \
  "$hooks/enforce-pr-claude.sh")"
[ -z "$claude_silent" ]

codex_silent="$(printf '%s' "$payload" | PATH="$tmp/bin:$PATH" MOCK_GH_MODE=present \
  TMPDIR="$tmp/runtime" "$hooks/enforce-pr-codex.sh")"
[ -z "$codex_silent" ]

printf '%s\n' '#!/usr/bin/env bash' 'echo "defect in app.py: broken branch"' 'exit 2' \
  > "$tmp/reviewer.sh"
chmod +x "$tmp/reviewer.sh"
review_output="$(printf '{}' | CODEX_LOCAL_REVIEWER="$tmp/reviewer.sh" \
  "$hooks/local-diff-review-codex.sh")"
printf '%s' "$review_output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["continue"] is False
assert "defect in app.py" in result["systemMessage"]
'

echo "PASS shared Claude and Codex hooks"
