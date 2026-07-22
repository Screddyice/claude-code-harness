#!/usr/bin/env bash
# Compatibility entry point. The implementation now lives with the shared hooks.

exec "$(dirname "$0")/hooks/local-diff-review-codex.sh"
