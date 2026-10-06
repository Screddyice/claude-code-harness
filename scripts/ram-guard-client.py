#!/usr/bin/env python3
"""RAM-gated llmjury/jury entry points; preserve the original pipx executable."""
import json
import os
from pathlib import Path
import subprocess
import sys


def local_options(args, client="llmjury"):
    if client == "qwen":
        command = args[1:] if args and args[0] in ("27b", "27B") else args
        safe = "--help" in command or "-h" in command or (command and command[0] in ("status", "stop"))
        return not safe, list(args)
    if not args or args[0] not in ("solve", "reproduce") or "--help" in args or "-h" in args:
        return False, list(args)
    backend = "openrouter"
    for index, arg in enumerate(args):
        if arg == "--backend" and index + 1 < len(args):
            backend = args[index + 1]
        elif arg.startswith("--backend="):
            backend = arg.split("=", 1)[1]
    local = backend == "ollama" or "--brain" in args
    result = list(args)
    def supplied(option):
        return any(arg == option or arg.startswith(option + "=") for arg in args)
    if backend == "ollama" and args[0] == "solve":
        # argparse uses the final occurrence: old off/warn choices cannot bypass
        # the user's installed safety policy.
        result += ["--mem-check", "refuse"]
        if not supplied("--models"):
            result += ["--models", "qwen3.5:4b,phi4-mini:3.8b"]
        if not supplied("--num-ctx"):
            result += ["--num-ctx", "8192"]
        if not supplied("--frontier") and not supplied("--frontier-backend"):
            result += ["--frontier", os.environ.get("LLMJURY_CODEX_MODEL", "gpt-5.6-sol"), "--frontier-backend", "codex"]
    return local, result


def main():
    home = Path.home()
    try:
        config = json.loads((home / ".local/state/ram-guard/clients.json").read_text())
        real = Path(config[Path(sys.argv[0]).name])
        if not real.is_file() or real.resolve() == Path(__file__).resolve():
            raise ValueError("original CLI is missing or recursive")
    except (OSError, KeyError, ValueError) as error:
        sys.exit(f"RAM guard: cannot resolve original CLI: {error}")
    local, args = local_options(sys.argv[1:], Path(sys.argv[0]).name)
    if local:
        result = subprocess.run([sys.executable, str(home / ".local/bin/ram-guard"), "check"])
        if result.returncode:
            return result.returncode
    os.execv(str(real), [str(real)] + args)


if __name__ == "__main__":
    raise SystemExit(main())
