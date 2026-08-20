#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TEST_HOME="$TMP_ROOT/home"
FAKE_BIN="$TMP_ROOT/bin"
FIXTURE="$TMP_ROOT/claude-fixture"
mkdir -p "$TEST_HOME" "$FAKE_BIN"

cat >"$FIXTURE" <<'EOF'
#!/usr/bin/env bash
echo "9.9.9 (Claude Code)"
EOF
chmod +x "$FIXTURE"
FIXTURE_SHA="$(shasum -a 256 "$FIXTURE" | cut -d' ' -f1)"
FIXTURE_SIZE="$(stat -f %z "$FIXTURE")"

cat >"$FAKE_BIN/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
url="\${!#}"
case "\$url" in
  */latest) printf '%s' '9.9.9' ;;
  */manifest.json)
    printf '%s' '{"platforms":{"darwin-arm64":{"checksum":"$FIXTURE_SHA","size":$FIXTURE_SIZE}}}'
    ;;
  */darwin-arm64/claude)
    out=""
    while [[ \$# -gt 0 ]]; do
      if [[ "\$1" == "-o" ]]; then out="\$2"; shift 2; else shift; fi
    done
    attempts="$TMP_ROOT/download-attempts"
    if [[ ! -f "\$attempts" ]]; then
      printf '1\n' >"\$attempts"
      head -c 8 "$FIXTURE" >"\$out"
      exit 56
    fi
    [[ -s "\$out" ]]
    cp "$FIXTURE" "\$out"
    ;;
  *) printf 'unexpected URL: %s\n' "\$url" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"

HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" CLAUDE_UPDATER_RETRY_DELAY=0 \
  "$ROOT/scripts/claude-manual-update" latest

[[ -L "$TEST_HOME/.local/bin/claude" ]]
[[ "$(cat "$TMP_ROOT/download-attempts")" == "1" ]]
[[ "$(readlink "$TEST_HOME/.local/bin/claude")" == "$TEST_HOME/.local/share/claude/versions/9.9.9" ]]
jq -e '
  .path == "native"
  and .outcome == "success"
  and .status == "success"
  and .version_from == "none"
  and .version_to == "9.9.9"
  and .error_code == null
' "$TEST_HOME/.claude/.last-update-result.json" >/dev/null

HOME="$TEST_HOME" CLAUDE_UPDATER_SKIP_LAUNCHCTL=1 \
  "$ROOT/scripts/install-claude-resilient-updater.sh"
HOME="$TEST_HOME" CLAUDE_UPDATER_SKIP_LAUNCHCTL=1 \
  "$ROOT/scripts/install-claude-resilient-updater.sh"

cmp "$ROOT/scripts/claude-manual-update" "$TEST_HOME/.local/bin/claude-manual-update"
plutil -lint "$TEST_HOME/Library/LaunchAgents/com.screddy.claude-resilient-updater.plist" >/dev/null
grep -q "$TEST_HOME/.local/bin/claude-manual-update" \
  "$TEST_HOME/Library/LaunchAgents/com.screddy.claude-resilient-updater.plist"

echo "claude resilient updater tests passed"
