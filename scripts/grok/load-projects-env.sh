#!/usr/bin/env bash
# Load workspace credentials into the current process (set -a).
# Source of truth: ~/projects/.env (never printed).
set -euo pipefail

ENV_FILE="${PROJECTS_ENV_FILE:-${HOME}/projects/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
