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
for tool in bash sed awk grep tr cat find wc date python3 jq id sleep seq mkdir dirname rm mv env cut ls sort ps; do
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
  # claude-mem's worker, on its own port. Up only when the fixture says so.
  */api/health)
    [ -f "$FIXTURE/mem-up" ] || exit 1
    printf '{"status":"ok","pid":%d}\n' "$$" ;;
  *)             exit 1 ;;
esac
EOF

cat > "$STUB/ollama" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE/ollama.log"
case "$1" in
  run) printf 'RAN %s\n' "$*" ;;
  stop)
    [ ! -f "$FIXTURE/stop-fails" ] || exit 42
    if [ ! -f "$FIXTURE/stop-keeps-resident" ]; then
      jq --arg name "$2" '.models = [.models[]? | select(.name != $name)]' \
        "$FIXTURE/ps.json" > "$FIXTURE/ps.next" && mv "$FIXTURE/ps.next" "$FIXTURE/ps.json"
    fi ;;
esac
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

# claude-mem starts its worker through node. The stub records that it was called
# and brings the fake worker up, so the wrapper's readiness poll can succeed.
cat > "$STUB/node" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE/node.log"
env > "$FIXTURE/node.env"
: > "$FIXTURE/mem-up"
exit 0
EOF

# Both agent stubs dump argv and the environment they were handed, which is the
# only thing worth asserting: the wrapper's whole job is to exec them correctly.
cat > "$STUB/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FIXTURE/claude.argv"
env > "$FIXTURE/claude.env"
exit 0
EOF

cat > "$STUB/codex" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FIXTURE/codex.argv"
env > "$FIXTURE/codex.env"
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
  rm -f "$FIXTURE/simulator" "$FIXTURE/ollama.log" \
        "$FIXTURE/stop-fails" "$FIXTURE/stop-keeps-resident" \
        "$FIXTURE/claude.argv" "$FIXTURE/claude.env" \
        "$FIXTURE/codex.argv" "$FIXTURE/codex.env" \
        "$FIXTURE/node.log" "$FIXTURE/node.env" "$FIXTURE/mem-up"
  # A claude-mem install the wrapper can find: newest version wins, and an
  # orphaned one is skipped even when it sorts higher.
  rm -rf "$FIXTURE/mem-cache"
  mkdir -p "$FIXTURE/mem-cache/13.24.5/scripts" \
           "$FIXTURE/mem-cache/13.24.23/scripts" \
           "$FIXTURE/mem-cache/13.24.99/scripts"
  for v in 13.24.5 13.24.23 13.24.99; do
    : > "$FIXTURE/mem-cache/$v/scripts/worker-service.cjs"
    : > "$FIXTURE/mem-cache/$v/scripts/bun-runner.js"
  done
  : > "$FIXTURE/mem-cache/13.24.99/.orphaned_at"
  rm -rf "$FIXTURE/leases" "$FIXTURE/state"
  mkdir -p "$FIXTURE/leases" "$FIXTURE/state"
}

run_qwen() {
  env -i PATH="$STUB" HOME="$FIXTURE" FIXTURE="$FIXTURE" \
    OLLAMA_HOST=127.0.0.1:11434 \
    QWEN_STATE_DIR="$FIXTURE/state" \
    QWEN_EVICTION_TIMEOUT="${QWEN_EVICTION_TIMEOUT:-30}" \
    LLMJURY_COMPUTE_LEASE_DIR="$FIXTURE/leases" \
    LLMJURY_LOCAL_LOCK="$FIXTURE/compute.lock" \
    CMEM_PRO_TOKEN=test-token-not-real \
    QWEN_CLAUDE_MEM_CACHE="$FIXTURE/mem-cache" \
    CLAUDE_MEM_WORKER_PORT=37799 \
    QWEN_MEMORY="${QWEN_MEMORY:-1}" \
    bash "$QWEN" "$@" 2>&1 </dev/null
}

claude_env() { grep -m1 "^$1=" "$FIXTURE/claude.env" | cut -d= -f2-; }
claude_argv_has() { grep -qxF -- "$1" "$FIXTURE/claude.argv"; }

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
touch "$FIXTURE/stop-fails"
out=$(run_qwen "hello")
case "$out" in
  *"failed to unload gemma3:12b"*"RAN run"*) fail "failed eviction refuses the load" "$out" ;;
  *"failed to unload gemma3:12b"*) pass "failed eviction refuses the load" ;;
  *) fail "failed eviction refuses the load" "$out" ;;
esac

reset_world
printf '{"models":[{"name":"gemma3:12b","size":11000000000}]}\n' > "$FIXTURE/ps.json"
touch "$FIXTURE/stop-keeps-resident"
QWEN_EVICTION_TIMEOUT=0 out=$(run_qwen "hello")
case "$out" in
  *"timed out waiting for Ollama to unload: gemma3:12b"*"RAN run"*) fail "incomplete eviction refuses the load" "$out" ;;
  *"timed out waiting for Ollama to unload: gemma3:12b"*) pass "incomplete eviction refuses the load" ;;
  *) fail "incomplete eviction refuses the load" "$out" ;;
esac

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

# --- agent sessions ---------------------------------------------------------

ALIAS=claude-haiku-4-5-20251001

# Claude Code 2.1.267 refuses any model id outside its compiled catalog, whatever
# ANTHROPIC_BASE_URL points at. Serving the same blobs under a catalog id is the
# only thing that worked, so the alias is load-bearing, not cosmetic.
reset_world
run_qwen claude >/dev/null
if grep -q "^cp $MODEL $ALIAS$" "$FIXTURE/ollama.log"; then
  pass "a missing catalog-id alias is created from the canonical tag"
else
  fail "a missing catalog-id alias is created" "$(cat "$FIXTURE/ollama.log")"
fi

reset_world
run_qwen claude >/dev/null
if [ "$(claude_env ANTHROPIC_BASE_URL)" = "http://127.0.0.1:11434" ] &&
   [ "$(claude_env ANTHROPIC_MODEL)" = "$ALIAS" ] &&
   [ "$(claude_env ANTHROPIC_DEFAULT_HAIKU_MODEL)" = "$ALIAS" ] &&
   [ "$(claude_env CLAUDE_CODE_SUBAGENT_MODEL)" = "$ALIAS" ]; then
  pass "every model slot points at the one alias, so only one runner loads"
else
  fail "every model slot points at the one alias" "$(grep -E '^(ANTHROPIC|CLAUDE_CODE)' "$FIXTURE/claude.env" | tr '\n' ' ')"
fi

# Backdoor's tier-swapping under a live session is what got it deleted.
reset_world
run_qwen claude >/dev/null
if [ "$(claude_env CLAUDE_CODE_NO_MODEL_FALLBACK)" = "1" ] &&
   [ "$(claude_env CLAUDE_CODE_MAX_CONTEXT_TOKENS)" = "32768" ]; then
  pass "fallback is off and the window is pinned to the model's context"
else
  fail "fallback is off and the window is pinned" "$(grep -E '^CLAUDE_CODE' "$FIXTURE/claude.env" | tr '\n' ' ')"
fi

reset_world
run_qwen claude >/dev/null
if grep -q '^ANTHROPIC_API_KEY=' "$FIXTURE/claude.env"; then
  fail "the real API key is not handed to a local server" "ANTHROPIC_API_KEY was forwarded"
else
  pass "the real API key is not handed to a local server"
fi

# The token is referenced by name. A copied secret would show up here as a value.
reset_world
run_qwen claude >/dev/null
mcp_arg=$(grep -m1 'mcpServers' "$FIXTURE/claude.argv" || true)
if claude_argv_has "--strict-mcp-config" &&
   printf '%s' "$mcp_arg" | grep -q 'Bearer \${CMEM_PRO_TOKEN}' &&
   ! printf '%s' "$mcp_arg" | grep -q 'test-token-not-real'; then
  pass "cmem is wired by env reference, with no token value in the argv"
else
  fail "cmem is wired by env reference" "$mcp_arg"
fi

reset_world
run_qwen claude --mcp none >/dev/null
if grep -q '{"mcpServers":{}}' "$FIXTURE/claude.argv"; then
  pass "--mcp none loads no MCP servers at all"
else
  fail "--mcp none loads no MCP servers" "$(cat "$FIXTURE/claude.argv" | tr '\n' ' ')"
fi

reset_world
run_qwen claude --mcp all >/dev/null
if claude_argv_has "--strict-mcp-config"; then
  fail "--mcp all leaves the user's own MCP config alone" "still passed --strict-mcp-config"
else
  pass "--mcp all leaves the user's own MCP config alone"
fi

# Tool schemas are the largest thing competing for a 32k window.
reset_world
run_qwen claude >/dev/null
if claude_argv_has "--disallowed-tools"; then
  pass "the default session drops the built-in tools and keeps MCP"
else
  fail "the default session drops the built-in tools" "$(cat "$FIXTURE/claude.argv" | tr '\n' ' ')"
fi

reset_world
run_qwen claude --tools all -p hi >/dev/null
if claude_argv_has "--disallowed-tools"; then
  fail "--tools all restricts nothing" "still passed --disallowed-tools"
else
  pass "--tools all restricts nothing"
fi

# The alias and the canonical tag are one model on one set of blobs. Unloading the
# alias "to make room" would evict the session that is using it.
reset_world
printf '{"models":[{"name":"%s:latest","size":17551390145}]}\n' "$ALIAS" > "$FIXTURE/ps.json"
run_qwen claude >/dev/null
if grep -q "^stop $ALIAS" "$FIXTURE/ollama.log"; then
  fail "the alias is never unloaded as a foreign model" "$(cat "$FIXTURE/ollama.log")"
else
  pass "the alias is never unloaded as a foreign model"
fi

# An agent session loads the blobs under the alias. Reporting that as "not loaded"
# plus a foreign resident model is how you end up holding 17 GB you think is free.
reset_world
printf '{"models":[{"name":"%s:latest","size":17551390145}]}\n' "$ALIAS" > "$FIXTURE/ps.json"
out=$(run_qwen status)
case "$out" in
  *"resident, 16.3 GB (as $ALIAS)"*) pass "status reports the alias as this model, not a foreign one" ;;
  *) fail "status reports the alias as this model" "$out" ;;
esac

reset_world
run_qwen stop >/dev/null
if grep -qx "stop $MODEL" "$FIXTURE/ollama.log" && grep -qx "stop $ALIAS" "$FIXTURE/ollama.log"; then
  pass "stop unloads both the canonical tag and the alias"
else
  fail "stop unloads both tags" "$(cat "$FIXTURE/ollama.log" | tr '\n' ' ')"
fi

# Codex has no model-id allowlist, so it takes the real tag over Ollama's OpenAI
# wire, and every setting is a -c override rather than an edit to config.toml.
reset_world
run_qwen codex >/dev/null
if grep -qxF "model_provider=qwen" "$FIXTURE/codex.argv" &&
   grep -qxF "model_providers.qwen.base_url=http://127.0.0.1:11434/v1" "$FIXTURE/codex.argv" &&
   grep -qxF "$MODEL" "$FIXTURE/codex.argv"; then
  pass "codex is pointed at Ollama's OpenAI wire with the real tag"
else
  fail "codex is pointed at Ollama's OpenAI wire" "$(cat "$FIXTURE/codex.argv" | tr '\n' ' ')"
fi

reset_world
run_qwen codex >/dev/null
cmem_arg=$(grep -m1 'mcp_servers=' "$FIXTURE/codex.argv" || true)
if printf '%s' "$cmem_arg" | grep -q 'bearer_token_env_var' &&
   ! printf '%s' "$cmem_arg" | grep -q 'test-token-not-real'; then
  pass "codex gets cmem by env-var name, with no token value in the argv"
else
  fail "codex gets cmem by env-var name" "$cmem_arg"
fi

# --- typing `qwen` opens Qwen ------------------------------------------------

# The whole point of the command: no agent, no harness, no wrapper in front of
# the model. A release where bare `qwen` started Claude Code is what this guards.
reset_world
out=$(run_qwen)
case "$out" in
  *"RAN run $MODEL"*) pass "bare qwen opens the model itself" ;;
  *) fail "bare qwen opens the model itself" "$out" ;;
esac
if [ -f "$FIXTURE/claude.argv" ]; then
  fail "bare qwen does not start an agent" "claude was executed"
else
  pass "bare qwen does not start an agent"
fi

reset_world
out=$(run_qwen raw)
case "$out" in
  *"RAN run $MODEL"*) pass "raw stays an alias for bare qwen" ;;
  *) fail "raw stays an alias for bare qwen" "$out" ;;
esac

reset_world
run_qwen agent >/dev/null
if [ -f "$FIXTURE/claude.argv" ] && [ "$(claude_env ANTHROPIC_BASE_URL)" = "http://127.0.0.1:11434" ]; then
  pass "agent is an alias for the claude session"
else
  fail "agent is an alias for the claude session" "claude was not executed"
fi

# --- the session says what is answering --------------------------------------

# Claude Code names every surface from the model id, and the id is a borrowed
# catalog entry, so without these the session calls itself Haiku 4.5 throughout.
reset_world
run_qwen claude >/dev/null
if [ "$(claude_env QWEN_SESSION_MODEL)" = "$MODEL" ] &&
   [ "$(claude_env ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME)" = "$MODEL (local)" ] &&
   [ "$(claude_env ANTHROPIC_DEFAULT_OPUS_MODEL_NAME)" = "$MODEL (local)" ]; then
  pass "the session is labelled with the local model, not the catalog id"
else
  fail "the session is labelled with the local model" \
       "$(grep -E '^(QWEN_SESSION_MODEL|ANTHROPIC_DEFAULT_.*_NAME)' "$FIXTURE/claude.env" | tr '\n' ' ')"
fi

# A slot left on a real Claude id 404s against Ollama the moment it is selected.
reset_world
run_qwen claude >/dev/null
if [ "$(claude_env ANTHROPIC_DEFAULT_FABLE_MODEL)" = "$ALIAS" ]; then
  pass "the fable slot points at the alias like every other slot"
else
  fail "the fable slot points at the alias" "$(claude_env ANTHROPIC_DEFAULT_FABLE_MODEL)"
fi

# --- claude-mem ---------------------------------------------------------------

# claude-mem's worker is one daemon for the machine, and its observer spawns the
# claude CLI with the DAEMON's environment. Started from inside this session it
# would inherit ANTHROPIC_BASE_URL and answer every session's memory compression
# from Ollama, so the wrapper starts it before that environment exists.
reset_world
run_qwen claude >/dev/null
if grep -q 'worker-service.cjs start' "$FIXTURE/node.log" 2>/dev/null; then
  pass "the claude-mem worker is started for a session that has none"
else
  fail "the claude-mem worker is started" "$(cat "$FIXTURE/node.log" 2>/dev/null)"
fi

reset_world
run_qwen claude >/dev/null
if grep -q '^ANTHROPIC_BASE_URL=' "$FIXTURE/node.env" 2>/dev/null; then
  fail "the worker never inherits the local base url" "ANTHROPIC_BASE_URL reached the worker"
else
  pass "the worker never inherits the local base url"
fi

# Newest non-orphaned install, version-sorted: 13.24.5 must not beat 13.24.23,
# and an orphaned 13.24.99 must not beat either.
reset_world
run_qwen claude >/dev/null
if grep -q '13\.24\.23/scripts/worker-service.cjs start' "$FIXTURE/node.log" 2>/dev/null; then
  pass "the newest non-orphaned claude-mem version is the one started"
else
  fail "the newest non-orphaned claude-mem version is started" "$(cat "$FIXTURE/node.log" 2>/dev/null)"
fi

reset_world
touch "$FIXTURE/mem-up"
run_qwen claude >/dev/null
if [ -f "$FIXTURE/node.log" ]; then
  fail "a healthy worker is left alone" "$(cat "$FIXTURE/node.log")"
else
  pass "a healthy worker is left alone"
fi

reset_world
out=$(QWEN_MEMORY=0 run_qwen claude)
if [ ! -f "$FIXTURE/node.log" ] && grep -q '{"mcpServers":{}}' "$FIXTURE/claude.argv"; then
  pass "QWEN_MEMORY=0 is offline: no recall server and no worker"
else
  fail "QWEN_MEMORY=0 is offline" "$out"
fi

# An explicit --mcp is a decision, and outranks the blanket switch.
reset_world
QWEN_MEMORY=0 run_qwen claude --mcp all >/dev/null
if claude_argv_has "--strict-mcp-config"; then
  fail "an explicit --mcp outranks QWEN_MEMORY=0" "still passed --strict-mcp-config"
else
  pass "an explicit --mcp outranks QWEN_MEMORY=0"
fi

reset_world
out=$(run_qwen claude --mcp bogus)
case "$out" in
  *"--mcp takes cmem, none or all"*) pass "an unknown --mcp value is refused" ;;
  *) fail "an unknown --mcp value is refused" "$out" ;;
esac

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo 'all qwen checks passed' || echo "$failures qwen check(s) failed")"
exit $(( failures > 0 ))
