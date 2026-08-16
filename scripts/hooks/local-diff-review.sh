#!/usr/bin/env bash

# Shared local-model reviewer. Claude Code consumes exit 2 and plain-text
# findings directly; the Codex adapter converts them to Codex Stop-hook JSON.

set -u

[ "${LOCAL_REVIEW:-1}" = "1" ] || exit 0
# Small model by default (2026-07-31). gemma3:12b meant a 13 GB load onto the GPU
# on every Stop with a changed diff.
#
# The "~3 GB" this comment used to claim for qwen3.5:4b was the weights only, and
# that was wrong in the expensive direction: Ollama sizes KV as num_ctx x
# OLLAMA_NUM_PARALLEL, so at 24576 ctx the tag measured 7.5 GB resident with
# `ollama ps`. Combined with a council on the same server that over-committed a
# 36 GB host and panicked it twice. Use the plain tag rather than -64k (same model
# ID, and num_ctx below is explicit anyway) so a dropped num_ctx cannot silently
# fall back to a 64k default. Set LOCAL_REVIEW_MODEL to override.
model="${LOCAL_REVIEW_MODEL:-qwen3.5:4b}"
ollama="${LOCAL_REVIEW_OLLAMA_URL:-http://127.0.0.1:11434}"
max_diff_bytes="${LOCAL_REVIEW_MAX_DIFF_BYTES:-60000}"
cache_dir="${LOCAL_REVIEW_CACHE_DIR:-$HOME/.cache/local-diff-review}"
# Minimum gap between reviews of the same repo. Collapses a burst of rapid turns
# into one review over the accumulated diff instead of one per turn.
cooldown="${LOCAL_REVIEW_COOLDOWN_SECONDS:-1200}"
# How long Ollama keeps the model resident after a review. Deliberately short: with
# a 20 minute cooldown the next review is far away, so lingering only holds GB that
# a council or another session needs. Trades a few seconds of reload for ~6 GB back.
keep_alive="${LOCAL_REVIEW_KEEP_ALIVE:-30s}"

# Durable memory for the reviewer, read from the offline Mem0 mirror.
#
# Every other local brain gets Mem0 at the proxy (src/proxy/memory.py in
# Screddyice/backdoor injects recall into any request routed through :8083).
# This hook talks to Ollama directly, so that injection never reaches it, and it
# was the last local model in the stack running with no memory.
#
# Sending the review through the router instead would fix that in one line and
# cost two things this hook cannot give up:
#
#   * keep_alive. The router picks its own; this hook needs 30s. Holding 7.5 GB
#     between turns is what over-committed this host and panicked it twice.
#   * model pinning. The router maps a `qwen*` name onto the heavy tier, so a
#     review would load 17 GB on every Stop instead of the 4B's 7.5 GB.
#
# It would also make reviews depend on the router being up, when today they only
# need Ollama. So recall is read here from the same SQLite mirror the proxy
# reads, with the same rules: read-only, budgeted, and fail-open.
memory_on="${LOCAL_REVIEW_MEMORY:-1}"
mem0_bin="${LOCAL_REVIEW_MEM0_BIN:-$HOME/.local/bin/mem0-local}"
# Small on purpose. num_ctx is 24576 and the diff can be 60 KB, so memory is a
# footnote to the diff, never a competitor for the window.
memory_chars="${LOCAL_REVIEW_MEMORY_CHARS:-1500}"
memory_max_files="${LOCAL_REVIEW_MEMORY_MAX_FILES:-5}"

top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
origin="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
case "$(printf %s "$origin" | tr '[:upper:]' '[:lower:]')" in
  *rs21*) exit 0 ;;
esac

base="$(git -C "$top" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')"
[ -n "$base" ] || base="origin/main"
merge_base="$(git -C "$top" merge-base HEAD "$base" 2>/dev/null || true)"
excludes=(':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.min.*'
          ':(exclude)dist/*' ':(exclude)build/*' ':(exclude)node_modules/*')
if [ -n "$merge_base" ]; then
  diff="$(git -C "$top" diff "$merge_base" -- . "${excludes[@]}" 2>/dev/null)"
  changed="$(git -C "$top" diff --name-only "$merge_base" -- . "${excludes[@]}" 2>/dev/null)"
else
  diff="$(git -C "$top" diff HEAD -- . "${excludes[@]}" 2>/dev/null)"
  changed="$(git -C "$top" diff --name-only HEAD -- . "${excludes[@]}" 2>/dev/null)"
fi
[ -n "$diff" ] || exit 0
[ "${#diff}" -le "$max_diff_bytes" ] || exit 0

mkdir -p "$cache_dir"
repo_key="$(printf %s "$top" | shasum -a 256 | cut -c1-16)"
diff_hash="$(printf %s "$diff" | shasum -a 256 | cut -c1-16)"
marker="$cache_dir/$repo_key"
stamp="$cache_dir/$repo_key.last"
[ "$(cat "$marker" 2>/dev/null)" = "$diff_hash" ] && exit 0

# Cooldown. Checked BEFORE the diff-hash marker is stamped: stamping on a skip
# would mark this diff "already reviewed", so an unchanged diff would never get
# reviewed once the cooldown expired.
now="$(date +%s)"
last="$(cat "$stamp" 2>/dev/null || true)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ "$(( now - last ))" -lt "$cooldown" ] && exit 0

printf %s "$diff_hash" > "$marker"
printf %s "$now" > "$stamp"

# LOCAL_REVIEW_DUMP_PROMPT prints the assembled system prompt and stops before
# any inference, so the memory wiring can be checked without loading a model onto
# a host that may already be holding one.
[ "${LOCAL_REVIEW_DUMP_PROMPT:-0}" = "1" ] || curl -sf -m 5 "$ollama/api/tags" >/dev/null 2>&1 || exit 0

review="$(DIFF="$diff" MODEL="$model" OLLAMA="$ollama" KEEP_ALIVE="$keep_alive" \
  CHANGED="$changed" MEMORY_ON="$memory_on" MEM0_BIN="$mem0_bin" \
  MEMORY_CHARS="$memory_chars" MEMORY_MAX_FILES="$memory_max_files" \
  DUMP_PROMPT="${LOCAL_REVIEW_DUMP_PROMPT:-0}" python3 - <<'PY' 2>/dev/null
import json
import os
import subprocess
import urllib.request

# Marker matches the one the proxy uses (src/proxy/memory.py), so a transcript
# from either path reads the same and the block is recognisable as injected
# context. Keep this heredoc free of apostrophes: bash 3.2, which is what
# /bin/bash still is on macOS, mis-parses one inside a heredoc nested in $(...)
# and the whole script dies with "unexpected EOF".
BLOCK_OPEN = "<durable-memory>"
BLOCK_CLOSE = "</durable-memory>"


def durable_memory() -> str:
    """Prior-work notes for the changed files, from the offline Mem0 mirror.

    `mem0-local filectx` only returns memories that actually name the file, so a
    review of one script does not drag in the rest of the corpus, and it never
    calls the Mem0 API — the mirror is local SQLite, so this costs no quota and
    works offline.

    Fail-open in every branch. A missing binary, a locked database, or a slow
    call returns nothing and the review proceeds without memory; a reviewer that
    refused to run because recall failed would be worse than one with no recall.
    """
    if os.environ.get("MEMORY_ON") != "1":
        return ""
    binary = os.environ.get("MEM0_BIN") or ""
    if not binary or not os.access(binary, os.X_OK):
        return ""

    try:
        budget = int(os.environ.get("MEMORY_CHARS") or 1500)
        max_files = int(os.environ.get("MEMORY_MAX_FILES") or 5)
    except ValueError:
        return ""

    paths = [p for p in (os.environ.get("CHANGED") or "").splitlines() if p.strip()]
    blocks: list[str] = []
    used = 0
    for path in paths[:max_files]:
        try:
            done = subprocess.run(
                [binary, "filectx", path, "--text"],
                capture_output=True,
                text=True,
                timeout=3,
            )
        except Exception:
            continue
        block = (done.stdout or "").strip()
        if not block:
            continue
        if used + len(block) > budget:
            break
        blocks.append(block)
        used += len(block)

    if not blocks:
        return ""
    return f"{BLOCK_OPEN}\n" + "\n\n".join(blocks) + f"\n{BLOCK_CLOSE}\n\n"


system = (
    "You are a strict code reviewer. Review this git diff and report ONLY "
    "definite defects: logic errors, broken behavior, security problems, "
    "data loss, crashes. Ignore style, naming, formatting, comments, and "
    "hypothetical concerns. For each defect give file, line context, and a "
    "one-sentence explanation. If there are no definite defects, output "
    "exactly: LGTM"
)

# Memory first, reviewer instructions last: the "output exactly LGTM" rule lands
# closest to the diff, which a 4B follows far more reliably than a rule buried
# above a wall of recalled notes. The proxy orders its injection the same way.
system = durable_memory() + system

if os.environ.get("DUMP_PROMPT") == "1":
    print(system)
    raise SystemExit(0)

payload = {
    "model": os.environ["MODEL"],
    "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": os.environ["DIFF"]},
    ],
    "stream": False,
    # Unload promptly. The cooldown means the next review is ~20 min out, so
    # staying resident only denies the GPU to whatever else needs it.
    "keep_alive": os.environ.get("KEEP_ALIVE", "30s"),
    "options": {"num_ctx": 24576, "num_predict": 600},
}
request = urllib.request.Request(
    os.environ["OLLAMA"] + "/api/chat",
    data=json.dumps(payload).encode(),
    headers={"content-type": "application/json"},
)
response = json.load(urllib.request.urlopen(request, timeout=480))
print((response.get("message", {}).get("content") or "").strip())
PY
)" || exit 0

if [ "${LOCAL_REVIEW_DUMP_PROMPT:-0}" = "1" ]; then
  printf '%s\n' "$review"
  exit 0
fi

[ -n "$review" ] || exit 0
case "$review" in LGTM*|lgtm*) exit 0 ;; esac

repo_name="$(basename "$top")"
printf 'Local reviewer (%s) flagged the current diff in %s:\n\n%s\n' "$model" "$repo_name" "$review"
exit 2
