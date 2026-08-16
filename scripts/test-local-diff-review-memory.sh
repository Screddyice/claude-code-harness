#!/usr/bin/env bash

# Durable-memory injection on the local diff reviewer.
#
# Every other local brain gets Mem0 at the proxy, which injects recall into any
# request routed through :8083. This hook calls Ollama directly, so that
# injection never reaches it and recall is read here instead, from the same
# offline mirror.
#
# Ollama is never reached in this test. LOCAL_REVIEW_DUMP_PROMPT=1 stops the
# hook once the system prompt is assembled and prints it, so the prompt itself
# is the observable and no model is loaded onto a host that may already be
# holding one.
#
# mem0-local is stubbed rather than used for real: the assertions are about the
# wiring (are changed files passed, is the budget honoured, does every failure
# degrade quietly), and a test that asserted on the real corpus would fail
# whenever that corpus changed.

set -eu

hook="$(cd "$(dirname "$0")" && pwd)/hooks/local-diff-review.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"

git -C "$repo" init -q
git -C "$repo" config user.email t@t.t
git -C "$repo" config user.name t
printf 'original\n' > "$repo/app.py"
printf 'original\n' > "$repo/util.py"
git -C "$repo" add -A
git -C "$repo" commit -qm init
printf 'changed\n' > "$repo/app.py"
printf 'changed\n' > "$repo/util.py"

# Stub mem0-local: echoes back the file it was asked about, so the prompt shows
# exactly which paths the hook forwarded.
stub="$tmp/mem0-local"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
# args: filectx <path> --text
printf 'PRIOR-WORK for %s\n' "$2"
STUB
chmod +x "$stub"

fresh_cache() { mktemp -d; }

run() {
  env -i PATH="$PATH" HOME="$HOME" \
    LOCAL_REVIEW_DUMP_PROMPT=1 \
    LOCAL_REVIEW_CACHE_DIR="$(fresh_cache)" \
    LOCAL_REVIEW_MEM0_BIN="$stub" \
    "$@" \
    bash -c "cd '$repo' && bash '$hook'"
}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Memory reaches the prompt, for every changed file.
out="$(run)"
case "$out" in
  *"<durable-memory>"*) : ;;
  *) fail "no durable-memory block in the prompt" ;;
esac
case "$out" in *"PRIOR-WORK for app.py"*) : ;; *) fail "app.py context missing" ;; esac
case "$out" in *"PRIOR-WORK for util.py"*) : ;; *) fail "util.py context missing" ;; esac

# 2. Reviewer instructions survive, and land AFTER the memory. A 4B follows the
#    LGTM rule far better when it sits closest to the diff.
case "$out" in *"exactly: LGTM"*) : ;; *) fail "reviewer instructions lost" ;; esac
memory_at="${out%%<durable-memory>*}"
rule_at="${out%%exactly: LGTM*}"
[ "${#memory_at}" -lt "${#rule_at}" ] || fail "memory block is not before the instructions"

# 3. Opt-out.
case "$(run LOCAL_REVIEW_MEMORY=0)" in
  *"<durable-memory>"*) fail "LOCAL_REVIEW_MEMORY=0 still injected" ;;
esac

# 4. Fail-open: a missing binary loses memory, never the review.
out="$(run LOCAL_REVIEW_MEM0_BIN=/nonexistent/mem0-local)"
case "$out" in *"<durable-memory>"*) fail "missing binary still injected" ;; esac
case "$out" in *"exactly: LGTM"*) : ;; *) fail "missing binary killed the review" ;; esac

# 5. Fail-open: a hanging recall cannot stall the Stop hook. The per-file
#    timeout is 3s, so a stub that sleeps past it must be abandoned, not waited
#    on. Anything near 10s here means the timeout stopped working.
slow="$tmp/mem0-slow"
printf '#!/usr/bin/env bash\nsleep 10\n' > "$slow"
chmod +x "$slow"
started="$(date +%s)"
out="$(run LOCAL_REVIEW_MEM0_BIN="$slow")"
elapsed=$(( $(date +%s) - started ))
case "$out" in *"exactly: LGTM"*) : ;; *) fail "hanging recall killed the review" ;; esac
[ "$elapsed" -lt 9 ] || fail "hanging recall was not timed out (${elapsed}s)"

# 6. Budget: memory is a footnote to the diff, never a competitor for num_ctx.
#    A budget smaller than one block admits none of it.
case "$(run LOCAL_REVIEW_MEMORY_CHARS=1)" in
  *"PRIOR-WORK"*) fail "char budget not enforced" ;;
esac

# 7. File cap, so a 40-file diff cannot fan out to 40 recall calls.
out="$(run LOCAL_REVIEW_MEMORY_MAX_FILES=1)"
case "$out" in *"PRIOR-WORK for app.py"*) : ;; *) fail "first file dropped under the cap" ;; esac
case "$out" in *"PRIOR-WORK for util.py"*) fail "file cap not enforced" ;; esac

printf 'OK: durable-memory injection, ordering, opt-out, fail-open, and budgets\n'
