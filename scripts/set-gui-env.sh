#!/bin/bash
# Publish selected credentials into the macOS GUI (Aqua) launchd domain at login.
#
# WHY: a Dock-launched app inherits launchd's environment, not a shell's, so an
# export in ~/.zshrc or a value in ~/projects/.env never reaches Codex Desktop.
# Its `cmem` MCP server declares `bearer_token_env_var = "CMEM_PRO_TOKEN"`, so
# without this the server loads with no token and its tools quietly do not
# appear — the failure looks like a missing feature rather than a missing
# credential.
#
# `launchctl setenv` alone is not enough: it lives only until logout or reboot.
# This runs at every login so the value is always current.
#
# The secret VALUE stays in ~/projects/.env. This script reads it there and
# hands it to launchd; it is never written into the plist, a log, or any file.
set -uo pipefail
ENV_FILE="${GUI_ENV_SOURCE:-$HOME/projects/.env}"
KEYS="${GUI_ENV_KEYS:-CMEM_PRO_TOKEN}"
[ -r "$ENV_FILE" ] || { echo "set-gui-env: no $ENV_FILE" >&2; exit 0; }
for key in $KEYS; do
  value=$(grep -m1 "^${key}=" "$ENV_FILE" | cut -d= -f2- | sed 's/^["'"'"']//; s/["'"'"']$//')
  if [ -n "$value" ]; then
    launchctl setenv "$key" "$value"
    echo "set-gui-env: published $key (${#value} chars) to the GUI domain"
  else
    echo "set-gui-env: $key not found in $ENV_FILE" >&2
  fi
done
