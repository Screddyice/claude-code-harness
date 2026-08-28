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

# --- PR base resolution -----------------------------------------------------
#
# Where a branch FORKED is not always where a PR may LAND. In a repo with an
# integration branch, trunk is a deploy branch: nebos-v2's guard-main-base.yml
# accepts only dev, promote/* and hotfix/* at main. A branch cut from main still
# scores main as its fork point, so the hook aimed there and CI rejected it on
# arrival — nebos-v2 #531 and #532, and #365 before them.

base_repo() {
  # $1 = dir, $2 = branch to create, rest = extra branches to create off main
  local d="$1" br="$2"; shift 2
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" -c user.name=T -c user.email=t@e.invalid commit --allow-empty -qm init
  git -C "$d" remote add origin https://github.com/example/repo.git
  # Remote-tracking refs: the resolver scores those alone when any exist.
  git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse main)"
  local extra
  for extra in "$@"; do
    git -C "$d" update-ref "refs/remotes/origin/$extra" "$(git -C "$d" rev-parse main)"
  done
  git -C "$d" switch -qc "$br"
  git -C "$d" -c user.name=T -c user.email=t@e.invalid commit --allow-empty -qm work
}

resolved_base() {
  ( cd "$1" && . "$hooks/hook-common.sh" && hook_load_branch_context >/dev/null 2>&1 \
      && printf '%s' "$HOOK_BASE_BRANCH" )
}

# A feature branch forked from main, in a repo that has dev, must aim at dev.
base_repo "$tmp/base-dev" "fix/thing" dev
got="$(resolved_base "$tmp/base-dev")"
[ "$got" = "dev" ] || { echo "FAIL: fix/* in a dev repo resolved to '$got', expected dev"; exit 1; }

# hotfix/* is an explicit escape hatch and keeps trunk.
base_repo "$tmp/base-hotfix" "hotfix/outage" dev
got="$(resolved_base "$tmp/base-hotfix")"
[ "$got" = "main" ] || { echo "FAIL: hotfix/* resolved to '$got', expected main"; exit 1; }

# A repo with no integration branch is untouched — most repos are this.
base_repo "$tmp/base-trunk" "fix/thing"
got="$(resolved_base "$tmp/base-trunk")"
[ "$got" = "main" ] || { echo "FAIL: trunk-only repo resolved to '$got', expected main"; exit 1; }

# The repo declaring its own base beats the hook guessing at it.
base_repo "$tmp/base-declared" "fix/thing" dev staging
mkdir -p "$tmp/base-declared/.claude-harness"
printf 'staging\n' > "$tmp/base-declared/.claude-harness/pr-base"
got="$(resolved_base "$tmp/base-declared")"
[ "$got" = "staging" ] || { echo "FAIL: declared base resolved to '$got', expected staging"; exit 1; }

echo "PR base resolution: ok"
