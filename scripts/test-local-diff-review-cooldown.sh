#!/usr/bin/env bash

# Cooldown gate on the local diff reviewer.
#
# The reviewer used to fire on every Stop where the branch diff changed, loading
# a 13 GB model onto the GPU dozens of times per session. It now skips when a
# review ran less than LOCAL_REVIEW_COOLDOWN_SECONDS ago.
#
# The cooldown is checked BEFORE the diff-hash marker is stamped. That ordering
# matters: stamping on a cooldown skip would mark the diff "already reviewed",
# and an unchanged diff would then never be reviewed once the cooldown expired.
#
# Ollama is never reached here. Pointing LOCAL_REVIEW_OLLAMA_URL at a dead port
# makes the hook exit right after the marker step, so "was the diff-hash marker
# written" is a clean observable for "did it get past the cooldown".

set -eu

hook="$(cd "$(dirname "$0")" && pwd)/hooks/local-diff-review.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
cache="$tmp/cache"
mkdir -p "$repo" "$cache"

git -C "$repo" init -q
git -C "$repo" config user.email t@t.t
git -C "$repo" config user.name t
printf 'original\n' > "$repo/app.py"
git -C "$repo" add app.py
git -C "$repo" commit -qm init
# Uncommitted change => `git diff HEAD` is non-empty, so the hook has work to do.
printf 'changed\n' > "$repo/app.py"

# The hook keys its cache on git's own toplevel. On macOS mktemp hands back
# /var/... while git resolves the symlink to /private/var/..., so ask git.
repo="$(git -C "$repo" rev-parse --show-toplevel)"
repo_key="$(printf %s "$repo" | shasum -a 256 | cut -c1-16)"
marker="$cache/$repo_key"
stamp="$cache/$repo_key.last"

run_hook() {
  ( cd "$repo" && \
    LOCAL_REVIEW_CACHE_DIR="$cache" \
    LOCAL_REVIEW_OLLAMA_URL="http://127.0.0.1:1" \
    "$hook" ) || true
}

# ── fresh stamp: skip, and do NOT consume the diff hash ──────────────────────
rm -f "$marker"
date +%s > "$stamp"
run_hook
[ ! -f "$marker" ] || {
  echo "FAIL cooldown skip stamped the diff-hash marker (diff would never be reviewed)" >&2
  exit 1
}

# ── expired stamp: proceed past the cooldown ─────────────────────────────────
rm -f "$marker"
echo $(( $(date +%s) - 4000 )) > "$stamp"
run_hook
[ -f "$marker" ] || { echo "FAIL expired cooldown did not proceed" >&2; exit 1; }

# ── no stamp at all (first ever run): proceed ────────────────────────────────
rm -f "$marker" "$stamp"
run_hook
[ -f "$marker" ] || { echo "FAIL first run with no stamp did not proceed" >&2; exit 1; }

# ── a corrupt stamp must not wedge the reviewer shut ─────────────────────────
rm -f "$marker"
printf 'not-a-number\n' > "$stamp"
run_hook
[ -f "$marker" ] || { echo "FAIL corrupt stamp blocked the reviewer" >&2; exit 1; }

# ── running a review records a fresh stamp for the next turn ─────────────────
rm -f "$marker" "$stamp"
run_hook
[ -f "$stamp" ] || { echo "FAIL review did not record a cooldown stamp" >&2; exit 1; }

# ── cooldown is configurable ─────────────────────────────────────────────────
rm -f "$marker"
echo $(( $(date +%s) - 100 )) > "$stamp"
( cd "$repo" && LOCAL_REVIEW_CACHE_DIR="$cache" \
  LOCAL_REVIEW_OLLAMA_URL="http://127.0.0.1:1" \
  LOCAL_REVIEW_COOLDOWN_SECONDS=10 "$hook" ) || true
[ -f "$marker" ] || { echo "FAIL LOCAL_REVIEW_COOLDOWN_SECONDS override ignored" >&2; exit 1; }

# ── default model is the small one (the GPU-cost decision, 2026-07-31) ───────
# Plain tag, not -64k: same model ID, but the -64k default context made this
# 3.4 GB model 7.5 GB resident, and it was held between turns. With an explicit
# num_ctx in the request the suffix bought nothing and cost memory the council
# needed. Asserting the plain tag keeps the suffix from creeping back.
grep -q 'LOCAL_REVIEW_MODEL:-qwen3.5:4b}' "$hook" || {
  echo "FAIL default review model is not qwen3.5:4b" >&2
  exit 1
}

# ── the model is released after the review, not held between turns ──────────
grep -q 'LOCAL_REVIEW_KEEP_ALIVE:-30s' "$hook" || {
  echo "FAIL default keep_alive is not 30s" >&2
  exit 1
}
grep -q '"keep_alive"' "$hook" || {
  echo "FAIL keep_alive is not sent in the request payload" >&2
  exit 1
}

echo "PASS local diff review cooldown"
