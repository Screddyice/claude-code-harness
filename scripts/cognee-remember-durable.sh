#!/usr/bin/env bash
# Durable Cognee remember: journal locally, send, verify by content hash, re-send until it lands.
# Logic lives in cognee_remember_durable.py next to this file.
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cognee_remember_durable.py" "$@"
