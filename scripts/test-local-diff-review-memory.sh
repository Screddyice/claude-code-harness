#!/usr/bin/env bash

# Free-memory gate on the local diff reviewer.
#
# The reviewer loads a ~7.5 GB model straight through Ollama's HTTP API. That
# path never touches llm-jury, so llm-jury's RAM preflight cannot protect it --
# the reviewer would load the model no matter how little memory was left.
#
# That mattered on 2026-07-31. This host panicked four times, and the failure was
# not a clean OOM: the VM compressor hit 100% of its SEGMENT limit while
# compressed pages sat at 38% of theirs, which wedges every thread that touches
# memory and starves watchdogd past its 90-second deadline. Anything that can
# claim multiple GB without looking at what is free is a contributor.
#
# Same observable as the cooldown test: LOCAL_REVIEW_OLLAMA_URL points at a dead
# port, so "was the diff-hash marker written" cleanly reports "did it get past
# the gates". A memory skip must NOT stamp the marker, or the diff would be
# recorded as reviewed and never looked at again once memory freed up.

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
printf 'changed\n' > "$repo/app.py"

repo="$(git -C "$repo" rev-parse --show-toplevel)"
repo_key="$(printf %s "$repo" | shasum -a 256 | cut -c1-16)"
marker="$cache/$repo_key"
stamp="$cache/$repo_key.last"

run_hook() {
  ( cd "$repo" && \
    LOCAL_REVIEW_CACHE_DIR="$cache" \
    LOCAL_REVIEW_OLLAMA_URL="http://127.0.0.1:1" \
    "$@" \
    "$hook" ) || true
}

# ── not enough free memory: skip, and do NOT consume the diff hash ───────────
# An absurd requirement no machine satisfies, so this asserts the gate exists
# rather than asserting anything about the host running the test.
rm -f "$marker" "$stamp"
run_hook env LOCAL_REVIEW_MIN_FREE_MB=99999999
[ ! -f "$marker" ] || {
  echo "FAIL reviewer loaded a multi-GB model without checking free memory" >&2
  exit 1
}

# ── memory gate disabled: proceed ───────────────────────────────────────────
rm -f "$marker" "$stamp"
run_hook env LOCAL_REVIEW_MIN_FREE_MB=0
[ -f "$marker" ] || { echo "FAIL LOCAL_REVIEW_MIN_FREE_MB=0 did not proceed" >&2; exit 1; }

# ── ample memory required: proceed on any normal host ───────────────────────
rm -f "$marker" "$stamp"
run_hook env LOCAL_REVIEW_MIN_FREE_MB=1
[ -f "$marker" ] || { echo "FAIL a 1 MB requirement blocked the reviewer" >&2; exit 1; }

# ── the gate must not wedge the reviewer shut when memory is unreadable ─────
# Same rule llm-jury's memguard follows: a guard that cannot measure must not
# become a new way for the run to fail.
rm -f "$marker" "$stamp"
run_hook env LOCAL_REVIEW_FREE_MB_OVERRIDE=unreadable
[ -f "$marker" ] || {
  echo "FAIL unreadable free memory blocked the reviewer instead of skipping the gate" >&2
  exit 1
}

# ── the default requirement must actually cover the default model ───────────
# qwen3.5:4b measured 7.5 GB resident at the context this hook requests. A
# default below that would let the gate pass right before an over-commit.
grep -qE 'LOCAL_REVIEW_MIN_FREE_MB:-(9[0-9]{3}|[1-9][0-9]{4,})' "$hook" || {
  echo "FAIL default LOCAL_REVIEW_MIN_FREE_MB does not cover a 7.5 GB model" >&2
  exit 1
}

echo "PASS local diff review memory guard"
