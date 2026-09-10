#!/bin/bash
# Coverage for scripts/qwen's admission path. Nothing here loads a model: Ollama,
# the memory probes and launchd are all stubbed, which is the only way to assert
# what the guard does when memory is short without actually making it short.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
QWEN="$ROOT/scripts/qwen"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/qwen-test.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; failures=$((failures + 1)); }

STUB="$FIXTURE/bin"
mkdir -p "$STUB"
# Everything the wrapper shells out to, except the six stubbed below. Linking the
# real binaries keeps the test honest: only Ollama and the memory probes are fake.
for tool in bash sed awk grep tr cat find wc date python3 jq id sleep seq mkdir dirname rm; do
  path=$(command -v "$tool") || continue
  ln -sf "$path" "$STUB/$tool"
done

# --- stubs ------------------------------------------------------------------
# Each reads its answer from the fixture, so a case sets the world by writing
# files rather than by editing the stub.

cat > "$STUB/curl" <<'EOF'
#!/bin/bash
url=""
for arg in "$@"; do case "$arg" in http*) url=$arg ;; esac; done
case "$url" in
  */api/version) echo '{"version":"0.0.0-test"}' ;;
  */api/tags)    cat "$FIXTURE/tags.json" ;;
  */api/ps)      cat "$FIXTURE/ps.json" ;;
  *)             exit 1 ;;
esac
EOF

cat > "$STUB/ollama" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE/ollama.log"
case "$1" in run) printf 'RAN %s\n' "$*" ;; esac
# The wrapper execs into `ollama run`, so this is where the lease must still be
# published: a lease that only exists before the exec protects nothing.
if [ "$1" = run ] && [ -n "$(find "$FIXTURE/leases" -maxdepth 1 -name '*.json' 2>/dev/null)" ]; then
  echo "LEASE_PRESENT" >> "$FIXTURE/ollama.log"
fi
exit 0
EOF

cat > "$STUB/memory_pressure" <<'EOF'
#!/bin/bash
echo "System-wide memory free percentage: $(cat "$FIXTURE/free_pct")%"
EOF

cat > "$STUB/sysctl" <<'EOF'
#!/bin/bash
case "$*" in
  *hw.memsize*)                        echo 38654705664 ;;
  *kern.memorystatus_vm_pressure_level*) cat "$FIXTURE/pressure" ;;
  *) exit 1 ;;
esac
EOF

cat > "$STUB/pgrep" <<'EOF'
#!/bin/bash
[ -f "$FIXTURE/simulator" ] && exit 0
exit 1
EOF

cat > "$STUB/launchctl" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$STUB"/*

MODEL=qwen3.8:27b-obliterated
# 16.5 GB on disk, which is what this tag actually reports.
printf '{"models":[{"name":"%s","size":17716740000}]}\n' "$MODEL" > "$FIXTURE/tags.json"

reset_world() {
  echo '{"models":[]}' > "$FIXTURE/ps.json"
  echo 1 > "$FIXTURE/pressure"
  echo 80 > "$FIXTURE/free_pct"
  rm -f "$FIXTURE/simulator" "$FIXTURE/ollama.log"
  rm -rf "$FIXTURE/leases" "$FIXTURE/state"
  mkdir -p "$FIXTURE/leases" "$FIXTURE/state"
}

run_qwen() {
  env -i PATH="$STUB" HOME="$FIXTURE" FIXTURE="$FIXTURE" \
    OLLAMA_HOST=127.0.0.1:11434 \
    QWEN_STATE_DIR="$FIXTURE/state" \
    LLMJURY_COMPUTE_LEASE_DIR="$FIXTURE/leases" \
    LLMJURY_LOCAL_LOCK="$FIXTURE/compute.lock" \
    bash "$QWEN" "$@" 2>&1
}

# --- cases ------------------------------------------------------------------

reset_world
out=$(run_qwen --help)
case "$out" in
  *"qwen status"*) pass "--help prints usage without touching Ollama" ;;
  *) fail "--help prints usage" "$out" ;;
esac

reset_world
out=$(run_qwen status)
case "$out" in
  *"not loaded"*) pass "status reports an unloaded model" ;;
  *) fail "status reports an unloaded model" "$out" ;;
esac

reset_world
printf '{"models":[{"name":"%s","size":17551390145}]}\n' "$MODEL" > "$FIXTURE/ps.json"
out=$(run_qwen status)
case "$out" in
  *"resident, 16.3 GB"*) pass "status reports resident size" ;;
  *) fail "status reports resident size" "$out" ;;
esac

# An elevated pressure level is memguard's own refusal condition; a wired
# over-commit panics the host rather than failing, so this must not be a warning.
reset_world
echo 2 > "$FIXTURE/pressure"
out=$(run_qwen "hello")
status=$?
case "$status:$out" in
  0:*) fail "elevated memory pressure refuses the load" "exited 0: $out" ;;
  *"memory pressure is elevated"*) pass "elevated memory pressure refuses the load" ;;
  *) fail "elevated memory pressure refuses the load" "$out" ;;
esac

reset_world
echo 20 > "$FIXTURE/free_pct"
out=$(run_qwen "hello")
case "$out" in
  *"needs ~"*) pass "too little free memory refuses the load" ;;
  *) fail "too little free memory refuses the load" "$out" ;;
esac

# --force is the documented escape hatch, and has to survive both refusals above.
reset_world
echo 20 > "$FIXTURE/free_pct"
echo 4 > "$FIXTURE/pressure"
out=$(run_qwen --force "hello")
case "$out" in
  *"RAN run $MODEL hello"*) pass "--force loads past the guard" ;;
  *) fail "--force loads past the guard" "$out" ;;
esac

reset_world
touch "$FIXTURE/simulator"
out=$(run_qwen "hello")
case "$out" in
  *"iOS Simulator is booted"*) pass "a booted Simulator refuses the load" ;;
  *) fail "a booted Simulator refuses the load" "$out" ;;
esac

reset_world
run_qwen "hello" >/dev/null
if grep -q '^LEASE_PRESENT$' "$FIXTURE/ollama.log"; then
  pass "the compute lease is published before the exec, not after"
else
  fail "the compute lease is published before the exec" "$(cat "$FIXTURE/ollama.log")"
fi

# Co-residency is the failure this whole script exists to prevent, so a smaller
# model already on the GPU is unloaded rather than tolerated.
reset_world
printf '{"models":[{"name":"gemma3:12b","size":11000000000}]}\n' > "$FIXTURE/ps.json"
run_qwen "hello" >/dev/null
if grep -q '^stop gemma3:12b$' "$FIXTURE/ollama.log"; then
  pass "another resident model is unloaded first"
else
  fail "another resident model is unloaded first" "$(cat "$FIXTURE/ollama.log")"
fi

reset_world
printf '{"models":[{"name":"gemma3:12b","size":11000000000}]}\n' > "$FIXTURE/ps.json"
run_qwen --keep-others "hello" >/dev/null
if grep -q '^stop gemma3:12b$' "$FIXTURE/ollama.log"; then
  fail "--keep-others leaves other models alone" "$(cat "$FIXTURE/ollama.log")"
else
  pass "--keep-others leaves other models alone"
fi

# Already resident means this session costs no new memory, so the guard that
# would otherwise refuse it must not run at all.
reset_world
echo 20 > "$FIXTURE/free_pct"
printf '{"models":[{"name":"%s","size":17551390145}]}\n' "$MODEL" > "$FIXTURE/ps.json"
out=$(run_qwen "hello")
case "$out" in
  *"attaching to the resident"*) pass "attaching to a resident model skips the guard" ;;
  *) fail "attaching to a resident model skips the guard" "$out" ;;
esac

# The reviewer and cooperating councils hold this same lock, nonblocking.
reset_world
python3 - "$FIXTURE/compute.lock" <<'PY' &
import fcntl, sys, time
handle = open(sys.argv[1], "a")
fcntl.flock(handle, fcntl.LOCK_EX)
time.sleep(10)
PY
holder=$!
sleep 1
out=$(run_qwen "hello")
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
case "$out" in
  *"owns compute"*) pass "a held compute lock refuses the load" ;;
  *) fail "a held compute lock refuses the load" "$out" ;;
esac

# `exec` skips the EXIT trap, so leases outlive their session by design; the next
# run is what clears them, and only once the owning pid is gone.
reset_world
printf '{"active":true,"model":"%s","pid":999999,"source":"qwen","expires_at":%d}\n' \
  "$MODEL" "$(( $(date +%s) + 3600 ))" > "$FIXTURE/leases/stale.json"
printf '{"active":true,"model":"%s","pid":%d,"source":"qwen","expires_at":%d}\n' \
  "$MODEL" "$$" "$(( $(date +%s) + 3600 ))" > "$FIXTURE/leases/live.json"
run_qwen status >/dev/null
if [ ! -f "$FIXTURE/leases/stale.json" ] && [ -f "$FIXTURE/leases/live.json" ]; then
  pass "a dead lease is pruned and a live one is kept"
else
  fail "a dead lease is pruned and a live one is kept" "$(ls "$FIXTURE/leases")"
fi

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo 'all qwen checks passed' || echo "$failures qwen check(s) failed")"
exit $(( failures > 0 ))
