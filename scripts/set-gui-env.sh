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
#
# It also publishes LLMJURY_OLLAMA_PARALLEL, which is derived rather than secret
# and so does not depend on the env file existing. llm-jury's memguard charges
# KV as num_ctx x this value and falls back to Ollama's default of 4 when it
# cannot see the real setting, so a GUI-launched session running the council
# overestimates and refuses work without it. It moved here on
# 2026-09-10 from the retired GUI environment helper.
set -uo pipefail
ENV_FILE="${GUI_ENV_SOURCE:-$HOME/projects/.env}"
KEYS="${GUI_ENV_KEYS:-CMEM_PRO_TOKEN}"

read_env_value() {
  local key="$1" source="$ENV_FILE" value
  if [ -r "$source" ]; then
    if [ "$(wc -l <"$source" 2>/dev/null)" = 1 ] && ! grep -q '=' "$source"; then
      source=$(cat "$source")
    fi
    if [ -r "$source" ]; then
      value=$(grep -m1 "^${key}=" "$source" | cut -d= -f2-)
      value="${value#\"}"; value="${value%\"}"
      value="${value#\'}"; value="${value%\'}"
      [ -n "$value" ] && { printf '%s' "$value"; return; }
    fi
  fi
  if [ "$key" = NEBOS_OS_BEARER_TOKEN ] && [ -r "$HOME/.claude.json" ]; then
    /opt/homebrew/bin/python3 - "$HOME/.claude.json" <<'PYTHON'
import json
import sys
try:
    config = json.load(open(sys.argv[1]))
    header = config["mcpServers"]["srcos"]["headers"]["Authorization"]
except (OSError, ValueError, KeyError, TypeError):
    raise SystemExit(0)
if isinstance(header, str) and header.lower().startswith("bearer "):
    print(header[7:].strip(), end="")
PYTHON
  fi
}

# Secrets. A missing file skips this block and leaves the derived value below
# alone, rather than exiting: the two have nothing to do with each other.
for key in $KEYS; do
  value=$(read_env_value "$key")
  if [ -n "$value" ]; then
    launchctl setenv "$key" "$value"
    echo "set-gui-env: published $key (${#value} chars) to the GUI domain"
  else
    echo "set-gui-env: $key not found in $ENV_FILE or ~/.claude.json" >&2
  fi
done

# Derived, not secret. Ollama's parallel-decode slots live in the server's own
# launchd unit, which exports them to the server process and nowhere else. Read
# the unit and republish the number under the name llm-jury looks for. An
# absent, malformed, or zero value unsets the variable instead of publishing a
# wrong one, since memguard's own conservative default beats a bad number.
OLLAMA_PLIST="${OLLAMA_PLIST:-$HOME/Library/LaunchAgents/com.screddy.ollama.plist}"
slots=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OLLAMA_NUM_PARALLEL' \
          "$OLLAMA_PLIST" 2>/dev/null)
case "$slots" in
  ''|*[!0-9]*|0)
    launchctl unsetenv LLMJURY_OLLAMA_PARALLEL
    echo "set-gui-env: no usable OLLAMA_NUM_PARALLEL in $OLLAMA_PLIST; unset LLMJURY_OLLAMA_PARALLEL" >&2
    ;;
  *)
    launchctl setenv LLMJURY_OLLAMA_PARALLEL "$slots"
    echo "set-gui-env: published LLMJURY_OLLAMA_PARALLEL=$slots to the GUI domain"
    ;;
esac

# Read the active job, not the saved plist: editing LLAMA_ARG_CACHE_RAM does
# not change the running server until it restarts. Unknown or unlimited caps
# keep memguard's conservative default by removing the GUI override.
ollama_job="${OLLAMA_LAUNCHD_TARGET:-gui/$(id -u)/com.screddy.ollama}"
cache_mib=$(launchctl print "$ollama_job" 2>/dev/null |
  awk '$1 == "LLAMA_ARG_CACHE_RAM" && $2 == "=>" { print $3 }')
case "$cache_mib" in
  ''|*[!0-9]*|0*)
    launchctl unsetenv LLMJURY_PROMPT_CACHE_MIB
    echo "set-gui-env: no bounded running Ollama cache; unset LLMJURY_PROMPT_CACHE_MIB" >&2
    ;;
  *)
    launchctl setenv LLMJURY_PROMPT_CACHE_MIB "$cache_mib"
    echo "set-gui-env: published LLMJURY_PROMPT_CACHE_MIB=$cache_mib from the running Ollama job"
    ;;
esac
