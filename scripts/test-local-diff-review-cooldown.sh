#!/usr/bin/env bash
# Exercise admission, cooldown and successful-inference markers against a fake
# local HTTP service. Failed/blocked requests must not consume the diff hash.
set -eu
exec python3 "$(cd "$(dirname "$0")" && pwd)/test-local-review-admission.py"
