#!/usr/bin/env bash
# Install the resilient updater and a six-hour macOS LaunchAgent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
STATE_DIR="$HOME/.local/state/claude-resilient-updater"
AGENT_DIR="$HOME/Library/LaunchAgents"
HELPER="$BIN_DIR/claude-manual-update"
PLIST="$AGENT_DIR/com.screddy.claude-resilient-updater.plist"
LABEL="com.screddy.claude-resilient-updater"

mkdir -p "$BIN_DIR" "$STATE_DIR" "$AGENT_DIR"
install -m 0755 "$ROOT/scripts/claude-manual-update" "$HELPER"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HELPER</string>
    <string>latest</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>21600</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$STATE_DIR/update.log</string>
  <key>StandardErrorPath</key>
  <string>$STATE_DIR/update.log</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null

if [[ "${CLAUDE_UPDATER_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
  DOMAIN="gui/$(id -u)"
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
fi

echo "installed resilient Claude updater: $HELPER"
echo "installed LaunchAgent: $PLIST"
