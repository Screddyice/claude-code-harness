#!/usr/bin/env python3
"""Host-local jury model defaults; preserve macOS and Ollama memory handling."""
import json
import os
from pathlib import Path
import sys

MODELS = "qwen3.5:4b,phi4-mini:3.8b"
CONTEXT = "8192"
SOLVE_OPTIONS = ("--task", "--tests", "--entry-point", "--cases", "--backend", "--k",
                 "--frontier-k", "--jobs", "--num-ctx", "--mem-check", "--think",
                 "--models", "--best", "--json", "--frontier", "--frontier-backend",
                 "--brain", "--brain-url", "--brain-model", "--help")


def option_name(argument):
    name = argument.split("=", 1)[0]
    if name in SOLVE_OPTIONS:
        return name
    matches = [option for option in SOLVE_OPTIONS if option.startswith(name)] if name.startswith("--") else []
    return matches[0] if len(matches) == 1 else None


def optimized_options(args):
    result = list(args)
    if not args or args[0] != "solve" or "--help" in args or "-h" in args:
        return result
    backend = "openrouter"
    for index, arg in enumerate(args):
        if option_name(arg) == "--backend" and "=" not in arg and index + 1 < len(args):
            backend = args[index + 1]
        elif option_name(arg) == "--backend" and "=" in arg:
            backend = arg.split("=", 1)[1]
    if backend != "ollama":
        return result
    def supplied(option):
        return any(option_name(arg) == option for arg in args)
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
