#!/bin/bash
# Tests for mcp-headers.py. `launchctl` is stubbed on PATH and the env file is a
# temp fixture, so nothing reads the real launchd domain or ~/projects/.env.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/mcp-headers.py"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/bash
# Answers only for LAUNCHD_ONLY_KEY, the way `launchctl getenv` does.
[ "$1" = getenv ] && [ "$2" = LAUNCHD_ONLY_KEY ] && { echo launchd-value; exit 0; }
exit 1
STUB
chmod +x "$TMP/bin/launchctl"

cat > "$TMP/env" <<'ENVF'
# comment
export FILE_KEY="file-value"
DUP_KEY=first
DUP_KEY='second'
ENVF

run() { env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" MCP_HEADERS_ENV_FILE="$TMP/env" "$@"; }
header() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[sys.argv[1]])' "$1"; }

out=$(run ENV_KEY=env-value python3 "$SCRIPT" x-api-key ENV_KEY)
[ "$(printf '%s' "$out" | header x-api-key)" = env-value ] \
  && ok "reads the process environment first" || no "env lookup" "$out"

out=$(run ENV_KEY=env-value python3 "$SCRIPT" Authorization ENV_KEY Bearer)
[ "$(printf '%s' "$out" | header Authorization)" = "Bearer env-value" ] \
  && ok "prefixes the scheme" || no "scheme" "$out"

out=$(run python3 "$SCRIPT" x-api-key LAUNCHD_ONLY_KEY)
[ "$(printf '%s' "$out" | header x-api-key)" = launchd-value ] \
  && ok "falls back to launchctl" || no "launchctl fallback" "$out"

out=$(run python3 "$SCRIPT" x-api-key FILE_KEY)
[ "$(printf '%s' "$out" | header x-api-key)" = file-value ] \
  && ok "falls back to the env file and strips export and quotes" || no "env file fallback" "$out"

out=$(run python3 "$SCRIPT" x-api-key DUP_KEY)
[ "$(printf '%s' "$out" | header x-api-key)" = second ] \
  && ok "takes the last assignment in the env file" || no "duplicate key" "$out"

out=$(run python3 "$SCRIPT" x-api-key MISSING_KEY 2>"$TMP/err"); rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ] && grep -q MISSING_KEY "$TMP/err"; then
  ok "a missing key exits 1, prints nothing, and names the key"
else
  no "missing key" "rc=$rc out=$out err=$(cat "$TMP/err")"
fi

run python3 "$SCRIPT" 'bad header' FILE_KEY >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "rejects an invalid header name" || no "bad header" "rc=$rc"

run python3 "$SCRIPT" x-api-key 'bad-var' >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "rejects an invalid variable name" || no "bad var" "rc=$rc"

run python3 "$SCRIPT" x-api-key FILE_KEY >/dev/null 2>"$TMP/err2"
! grep -q file-value "$TMP/err2" && ok "never writes the value to stderr" || no "stderr leak" "$(cat "$TMP/err2")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
