#!/usr/bin/env python3
"""Print one HTTP header as JSON for a Claude Code MCP server's headersHelper.

Usage: mcp-headers.py HEADER VAR [SCHEME]

Claude Code runs an http server's `headersHelper` command at connect time and
sends the JSON object it prints as request headers. This reads VAR from the
process environment, then the macOS GUI launchd domain, then ~/projects/.env
(MCP_HEADERS_ENV_FILE overrides the path), so the MCP config names a variable
and never holds its value. SCHEME, when given, prefixes the value ("Bearer").

Errors name the variable, never the value, and exit nonzero so Claude Code
reports the server as failed instead of connecting without credentials.
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

HEADER = re.compile(r"^[A-Za-z0-9-]+$")
VAR = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def from_launchctl(name):
    if sys.platform != "darwin":
        return ""
    try:
        result = subprocess.run(["launchctl", "getenv", name], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def from_env_file(name):
    path = Path(os.environ.get("MCP_HEADERS_ENV_FILE") or Path.home() / "projects/.env")
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return ""
    value = ""
    # Last assignment wins, as it does when a shell sources the file.
    for line in lines:
        key, sep, raw = line.strip().removeprefix("export ").strip().partition("=")
        if not sep or key.strip() != name:
            continue
        try:
            parts = shlex.split(raw, comments=True)
        except ValueError:
            continue
        if len(parts) == 1 and parts[0]:
            value = parts[0]
    return value


def main(argv):
    if len(argv) not in (2, 3) or not HEADER.match(argv[0]) or not VAR.match(argv[1]):
        print("usage: mcp-headers.py HEADER VAR [SCHEME]", file=sys.stderr)
        return 2
    header, name = argv[0], argv[1]
    value = os.environ.get(name, "").strip() or from_launchctl(name) or from_env_file(name)
    if not value:
        print(f"mcp-headers: {name} is not set in the environment, launchctl, or the env file", file=sys.stderr)
        return 1
    if len(argv) == 3:
        value = f"{argv[2]} {value}"
    print(json.dumps({header: value}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
