#!/usr/bin/env bash
# gstack-browser-shim.sh — gate gstack's bundled Chromium behind an explicit opt-in.
#
# gstack's /browse family (qa, design-review, canary, benchmark, design-html,
# office-hours, ...) resolves $B to <gstack>/browse/dist/browse and drives a
# Playwright headless Chromium daemon. Policy on this machine: browse through
# the host's own browser surface unless a job genuinely needs headless.
#
#   Claude Code → mcp__claude-in-chrome__* against the default browser
#   Codex       → the chrome / browser / computer-use plugins
#
# Both gstack installs are gated (2026-08-24). The real binaries stay next to
# the shims as browse-chromium.real and run on demand:
#
#   GSTACK_HEADLESS=1 <browse> <cmd>   # one command against the real binary
#   browse-headless <cmd>              # same thing, on PATH
#
# dist/ is gitignored and gstack has auto_upgrade:true, so a rebuild restores
# the real binary. This runs at SessionStart and before every Bash call.
#
# Revert:  mv browse/dist/browse-chromium.real browse/dist/browse   (per install)
#          and drop the hooks from ~/.claude/settings.json
set -uo pipefail

MARKER="gstack-browser-shim:claude-extension:v3"
ROOTS=("$HOME/.claude/skills/gstack" "$HOME/.agents/skills/gstack")
[ -n "${GSTACK_INSTALL_DIR:-}" ] && ROOTS=("$GSTACK_INSTALL_DIR")
PRIMARY_SHIM="$HOME/.claude/skills/gstack/browse/dist/browse"

write_shim() {
  cat > "$1" <<'SHIMEOF'
#!/usr/bin/env bash
# gstack-browser-shim:claude-extension:v3
#
# Default: browse through the host's own browser surface.
# Opt-in:  GSTACK_HEADLESS=1 (or `browse-headless`) runs the real headless
#          Chromium binary, preserved as browse-chromium.real alongside.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL="$SELF_DIR/browse-chromium.real"

# ── Escape hatch: deliberate headless run ────────────────────────────────────
if [ "${GSTACK_HEADLESS:-}" = "1" ] && [ -x "$REAL" ]; then
  exec "$REAL" "$@"
fi

CMD="${1:-}"

banner() {
  cat <<'TXT'
gstack browser: gated (harness policy)

Default path — use the browser surface your host already has:
  Claude Code → mcp__claude-in-chrome__* against the default browser.
                list_connected_browsers → select_browser on the existing
                connection (never switch_browser / re-pair), then
                tabs_context_mcp / tabs_create_mcp.
  Codex       → the chrome, browser, and computer-use plugins.

Headless is still available when a job actually needs it (bulk crawls, work
that must not touch the user's real browser session, pages the host surface
cannot reach, long unattended runs):
  GSTACK_HEADLESS=1 browse <cmd>     — or —     browse-headless <cmd>
The daemon idles out after 300s; `browse stop` ends it immediately.
TXT
}

mapping() {
  cat <<'TXT'

browse command            → Claude extension tool (Claude Code)
  goto / newtab <url>       navigate  (or tabs_create_mcp for a new tab)
  text / html / links /
    forms / accessibility /
    snapshot                read_page  (get_page_text for raw text; find to locate)
  click / hover / type /
    press / scroll /
    screenshot              computer
  fill / select             form_input
  viewport <WxH>            resize_window
  js / eval                 javascript_tool
  console                   read_console_messages
  network                   read_network_requests
  tabs / tab / closetab     tabs_context_mcp / tabs_close_mcp
  upload                    file_upload
  cookie-import*            not needed — the extension uses the real session
TXT
}

case "$CMD" in
  # Stop really stops, so a deliberate headless session ends through the normal
  # command. Never spawns anything.
  stop|kill)
    pkill -f "gstack/browse/src/server.ts"          2>/dev/null
    pkill -f "gstack/browse/src/terminal-agent.ts"  2>/dev/null
    pkill -f "ms-playwright/chromium_headless_shell" 2>/dev/null
    exit 0 ;;
  # Quiet success so /gstack-upgrade and friends don't read a gated browser
  # as a crashed daemon.
  restart|disconnect)
    exit 0 ;;
  status)
    if pgrep -f "gstack/browse/src/server.ts" >/dev/null 2>&1; then
      echo "A headless browse daemon is RUNNING (started with GSTACK_HEADLESS=1)."
      echo "Drive it with: GSTACK_HEADLESS=1 browse <cmd>   |   stop it: browse stop"
      echo
    fi
    banner
    exit 0 ;;
  --version|-v|version)
    echo "browse (gated shim — default path is the host browser surface)"
    exit 0 ;;
  ""|--help|-h|help)
    banner; mapping
    exit 0 ;;
esac

# Navigation: open the URL in the system default browser, then hand off.
if [ "$CMD" = "goto" ] || [ "$CMD" = "newtab" ]; then
  URL="${2:-}"
  if [ -n "$URL" ]; then
    case "$(uname -s)" in
      Darwin) open "$URL" >/dev/null 2>&1 || true ;;
      Linux)  xdg-open "$URL" >/dev/null 2>&1 || true ;;
    esac
    echo "Opened in the system default browser: $URL"
  fi
  banner; mapping
  exit 2
fi

echo "Gated: 'browse $CMD' would launch gstack's bundled Chromium."
banner; mapping
exit 2
SHIMEOF
  chmod +x "$1"
}

install_wrapper() {
  local w="$HOME/.local/bin/browse-headless"
  [ -d "$HOME/.local/bin" ] || mkdir -p "$HOME/.local/bin" 2>/dev/null || return 0
  if [ ! -f "$w" ] || ! grep -q "$MARKER" "$w" 2>/dev/null; then
    cat > "$w" <<WRAP
#!/usr/bin/env bash
# $MARKER (escape hatch)
# Run gstack's real headless browser on purpose. Everything else in the harness
# browses through the host's own browser surface.
# The daemon self-shuts-down after 300s idle; 'browse-headless stop' ends it now.
exec env GSTACK_HEADLESS=1 "$PRIMARY_SHIM" "\$@"
WRAP
    chmod +x "$w"
  fi
}

for GS in "${ROOTS[@]}"; do
  DIST="$GS/browse/dist"
  SHIM="$DIST/browse"
  REAL="$DIST/browse-chromium.real"
  [ -d "$DIST" ] || continue

  # Already current? Skip.
  if [ -f "$SHIM" ] && grep -q "$MARKER" "$SHIM" 2>/dev/null; then
    continue
  fi

  # Preserve the real binary (only when what's there is a real binary, not an
  # older shim we wrote).
  if [ -f "$SHIM" ] && ! grep -q "gstack-browser-shim:claude-extension" "$SHIM" 2>/dev/null; then
    mv -f "$SHIM" "$REAL" 2>/dev/null || continue
  fi

  write_shim "$SHIM"
done

install_wrapper
exit 0
