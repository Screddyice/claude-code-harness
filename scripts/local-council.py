#!/usr/bin/env python3
"""Host-local jury model defaults; preserve macOS and Ollama memory handling."""
import json
import os
from pathlib import Path
import sys

MODELS = "qwen3.5:4b,phi4-mini:3.8b"
CONTEXT = "8192"


def optimized_options(args):
    result = list(args)
    if not args or args[0] != "solve" or "--help" in args or "-h" in args:
        return result
    backend = "openrouter"
    for index, arg in enumerate(args):
        if arg == "--backend" and index + 1 < len(args):
            backend = args[index + 1]
        elif arg.startswith("--backend="):
            backend = arg.split("=", 1)[1]
    if backend != "ollama":
        return result
    def supplied(option):
        return any(arg == option or arg.startswith(option + "=") for arg in args)
    if not supplied("--models"):
        result += ["--models", MODELS]
    if not supplied("--num-ctx"):
        result += ["--num-ctx", CONTEXT]
    if not supplied("--frontier") and not supplied("--frontier-backend"):
        result += ["--frontier", os.environ.get("LLMJURY_CODEX_MODEL", "gpt-5.6-sol"), "--frontier-backend", "codex"]
    return result


def main():
    try:
        config = json.loads((Path.home() / ".config/llmjury/local-council.json").read_text())
        original = Path(config[Path(sys.argv[0]).name])
        if not original.is_file() or original.resolve() == Path(__file__).resolve():
            raise ValueError("original jury CLI is missing or recursive")
    except (OSError, KeyError, ValueError) as error:
        sys.exit(f"local council: cannot resolve original CLI: {error}")
    os.execv(str(original), [str(original)] + optimized_options(sys.argv[1:]))


if __name__ == "__main__":
    main()
