#!/usr/bin/env bash
# Tests for audit-stale-instructions.sh.
#
# The point of these is that an audit which always passes is worse than no
# audit: it is the same silent-success failure it exists to catch. So the first
# assertion is that it can fail at all.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/audit-stale-instructions.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

cat > "$TMP/stale.md" <<'MD'
# Notes

Cross-session memory is Cognee. Search it before re-deriving prior decisions.
The server is reached on 127.0.0.1:8001.

An unrelated paragraph that names nothing retired.
MD
out=$(bash "$AUDIT" "$TMP/stale.md" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "a stale instruction fails the audit" || no "a stale instruction fails" "rc=$rc"
grep -q 'Cross-session memory is Cognee' <<<"$out" && ok "it names the offending line" || no "names the offending line" "$out"
[ "$(grep -c '^/' <<<"$out")" = 1 ] && ok "it reports one line per paragraph, not per match" || no "one line per paragraph" "$out"

cat > "$TMP/history.md" <<'MD'
# Notes

Cognee was deleted on 2026-09-04 and nothing listens on 127.0.0.1:8001 any more.
Cross-session memory is claude-mem.
MD
bash "$AUDIT" "$TMP/history.md" >/dev/null 2>&1 \
  && ok "a retirement written as history passes" \
  || no "history passes" "$(bash "$AUDIT" "$TMP/history.md" 2>&1)"

cat > "$TMP/clean.md" <<'MD'
# Notes

Memory is claude-mem, read through the hosted hub and written to the local worker.
MD
bash "$AUDIT" "$TMP/clean.md" >/dev/null 2>&1 && ok "a clean file passes" || no "clean file passes" ""

out=$(STALE_PATTERN='widgetron' bash "$AUDIT" "$TMP/clean.md" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "STALE_PATTERN selects what counts as retired" || no "STALE_PATTERN is honoured" "$out"
cat > "$TMP/widget.md" <<'MD'
# Notes

The widgetron service is canonical for everything.
MD
STALE_PATTERN='widgetron' bash "$AUDIT" "$TMP/widget.md" >/dev/null 2>&1 \
  && no "STALE_PATTERN should catch a custom term" "" \
  || ok "STALE_PATTERN catches a custom term"

bash "$AUDIT" "$TMP/missing.md" >/dev/null 2>&1 && ok "a missing file is not an error" || no "missing file is not an error" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
