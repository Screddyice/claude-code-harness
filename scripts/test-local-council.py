#!/usr/bin/env python3
"""Offline routing and transparent CLI delegation checks."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("council", Path(__file__).with_name("local-council.py"))
council = importlib.util.module_from_spec(spec)
spec.loader.exec_module(council)


class CouncilTests(unittest.TestCase):
    def test_smaller_defaults_and_codex_fallback(self):
        args = council.optimized_options(["solve", "--backend", "ollama"])
        self.assertEqual(args[args.index("--models") + 1], "qwen3.5:4b,phi4-mini:3.8b")
        self.assertEqual(args[args.index("--num-ctx") + 1], "8192")
        self.assertEqual(args[-2:], ["--frontier-backend", "codex"])
        self.assertNotIn("--mem-check", args)

    def test_remote_and_help_commands_pass_through(self):
        for args in (["--version"], ["solve", "--backend", "codex"], ["preflight", "--models", "chosen"], ["solve", "--backend=ollama", "--help"]):
            self.assertEqual(council.optimized_options(args), args)

    def test_explicit_model_context_and_frontier_are_preserved(self):
        args = ["solve", "--backend=ollama", "--models=chosen", "--num-ctx", "4096", "--frontier", "chosen", "--frontier-backend", "codex", "--mem-check", "refuse"]
        self.assertEqual(council.optimized_options(args), args)

    def test_last_backend_option_wins(self):
        args = ["solve", "--backend=ollama", "--backend", "codex"]
        self.assertEqual(council.optimized_options(args), args)

    def test_install_is_idempotent_and_exec_preserves_arguments(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            binary = home / ".local/bin"
            binary.mkdir(parents=True)
            original = home / "original-cli"
            original.write_text("#!" + sys.executable + "\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n")
            original.chmod(0o755)
            for name in ("llmjury", "jury"):
                (binary / name).symlink_to(original)
            env = {**os.environ, "HOME": str(home)}
            installer = str(Path(__file__).with_name("install-local-council.py"))
            for _ in range(2):
                subprocess.run([sys.executable, installer], env=env, check=True, capture_output=True)
            for name in ("llmjury", "jury"):
                result = subprocess.run([str(binary / name), "solve", "--backend", "ollama", "--task", "task with spaces.txt"], env=env, check=True, capture_output=True, text=True)
                args = json.loads(result.stdout)
                self.assertIn("task with spaces.txt", args)
                self.assertEqual(args[args.index("--models") + 1], council.MODELS)
            config = json.loads((home / ".config/llmjury/local-council.json").read_text())
            self.assertEqual(config, {"llmjury": str(original.resolve()), "jury": str(original.resolve())})


if __name__ == "__main__":
    unittest.main()
