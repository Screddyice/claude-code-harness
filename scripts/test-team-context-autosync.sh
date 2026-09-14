#!/usr/bin/env bash

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
hook="$repo_root/scripts/hooks/team-context-autosync.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

origin="$tmp/origin.git"
repo="$tmp/team-context"

git init -q --bare "$origin"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name Test
git -C "$repo" remote add origin "$origin"
mkdir -p "$repo/memory"
printf 'base\n' > "$repo/memory/records.jsonl"
git -C "$repo" add memory/records.jsonl
git -C "$repo" commit -qm base
git -C "$repo" push -q origin main

printf 'main local record\n' >> "$repo/memory/records.jsonl"
TEAM_CONTEXT_DIR="$repo" "$hook" now

[ -z "$(git -C "$repo" status --porcelain -- memory projects-context)" ] \
  || { echo "FAIL: protected-branch sync should commit tracked paths locally" >&2; exit 1; }
[ "$(git --git-dir="$origin" rev-list --count main)" = "1" ] \
  || { echo "FAIL: protected-branch sync should not push to main" >&2; exit 1; }
grep -q 'skipped: on main (protected)' "$repo/.memory-autosync.log" \
  || { echo "FAIL: protected-branch push skip was not logged" >&2; exit 1; }

git -C "$repo" switch -qc feat/sync
printf 'branch\n' >> "$repo/memory/records.jsonl"
git -C "$repo" commit -qam branch

bad_origin="$tmp/missing-origin.git"
git -C "$repo" remote set-url origin "$bad_origin"
printf 'local record\n' >> "$repo/memory/records.jsonl"
TEAM_CONTEXT_DIR="$repo" "$hook" now

[ -z "$(git -C "$repo" status --porcelain -- memory projects-context)" ] \
  || { echo "FAIL: first sync should leave tracked paths clean after committing" >&2; exit 1; }
! git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 \
  || { echo "FAIL: failed first push should not have an upstream yet" >&2; exit 1; }
grep -q 'fail: push' "$repo/.memory-autosync.log" \
  || { echo "FAIL: failed push was not logged" >&2; exit 1; }

git -C "$repo" remote set-url origin "$origin"
TEAM_CONTEXT_DIR="$repo" "$hook" now

[ "$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" = "origin/feat/sync" ] \
  || { echo "FAIL: retry push should establish upstream tracking" >&2; exit 1; }
[ "$(git -C "$repo" rev-list --count '@{upstream}..HEAD')" = "0" ] \
  || { echo "FAIL: second sync should push the clean, already-committed record" >&2; exit 1; }
grep -q 'pushed .* -> feat/sync' "$repo/.memory-autosync.log" \
  || { echo "FAIL: retry push was not logged" >&2; exit 1; }

echo "PASS team-context autosync push retry"
