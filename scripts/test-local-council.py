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
from unittest import mock

spec = importlib.util.spec_from_file_location("council", Path(__file__).with_name("local-council.py"))
council = importlib.util.module_from_spec(spec)
spec.loader.exec_module(council)
installer_spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install-local-council.py"))
installer = importlib.util.module_from_spec(installer_spec)
installer_spec.loader.exec_module(installer)


class CouncilTests(unittest.TestCase):
    def make_installation(self, home):
        binary = home / ".local/bin"
        binary.mkdir(parents=True)
        original = home / "original-cli"
        original.write_text("#!" + sys.executable + "\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n")
        original.chmod(0o755)
        for name in ("llmjury", "jury"):
            (binary / name).symlink_to(original)
        config = home / ".config/llmjury/local-council.json"
        config.parent.mkdir(parents=True)
        return binary, original, config

    def test_colliding_wrapper_preserves_unrelated_tool(self):
        for symlink in (True, False):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as temporary:
                binary, original, config = self.make_installation(Path(temporary))
                wrapper = binary / "local-council"
                unrelated = binary / "unrelated-tool" if symlink else wrapper
                unrelated.write_text("unrelated tool\n")
                unrelated.chmod(0o700)
                if symlink:
                    wrapper.symlink_to(unrelated)
                with self.assertRaises(SystemExit):
                    installer.install(wrapper, config)
                self.assertEqual(unrelated.read_text(), "unrelated tool\n")
                self.assertEqual(unrelated.stat().st_mode & 0o777, 0o700)
                self.assertFalse(config.exists())
                self.assertEqual((binary / "llmjury").resolve(), original.resolve())

    def test_failed_reinstall_keeps_both_aliases_working(self):
        for failure in ("copy", "config", "publish"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                home = Path(temporary)
                binary, original, config = self.make_installation(home)
                wrapper = binary / "local-council"
                installer.install(wrapper, config)
                before = (wrapper.read_bytes(), config.read_bytes())
                real_write, real_replace = Path.write_text, Path.replace
                def failed_copy(source, target):
                    Path(target).write_text("invalid partial Python")
                    raise OSError(28, "disk full")
                def failed_write(path, *args, **kwargs):
                    real_write(path, "partial")
                    raise OSError(28, "disk full")
                def failed_replace(path, target):
                    if Path(target) == wrapper:
                        raise OSError("wrapper publish failed")
                    return real_replace(path, target)
                patch = {"copy": mock.patch.object(installer.shutil, "copyfile", failed_copy),
                         "config": mock.patch.object(Path, "write_text", failed_write),
                         "publish": mock.patch.object(Path, "replace", failed_replace)}[failure]
                with patch, self.assertRaises(OSError):
                    installer.install(wrapper, config)
                self.assertEqual((wrapper.read_bytes(), config.read_bytes()), before)
                for name in ("llmjury", "jury"):
                    result = subprocess.run([str(binary / name), "--version"], env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, check=True)
                    self.assertEqual(json.loads(result.stdout), ["--version"])

    def test_invalid_saved_originals_are_rejected_without_changes(self):
        for saved in ({"jury": "/missing-original"}, {"../outside": "/missing-original"}, {"jury": None}, []):
            with self.subTest(saved=saved), tempfile.TemporaryDirectory() as temporary:
                binary, original, config = self.make_installation(Path(temporary))
                (binary / "jury").unlink()
                config.write_text(json.dumps(saved))
                before = config.read_bytes()
                with self.assertRaises(SystemExit):
                    installer.install(binary / "local-council", config)
                self.assertEqual(config.read_bytes(), before)
                self.assertFalse((binary / "local-council").exists())
                self.assertEqual((binary / "llmjury").resolve(), original.resolve())

    def test_failed_first_alias_publish_can_be_retried(self):
        for error in (OSError, KeyboardInterrupt):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as temporary:
                binary, original, config = self.make_installation(Path(temporary))
                wrapper = binary / "local-council"
                real_replace = Path.replace
                def failed_alias(path, target):
                    if Path(target) == binary / "llmjury":
                        raise error("alias publish failed")
                    return real_replace(path, target)
                with mock.patch.object(Path, "replace", failed_alias), self.assertRaises(error):
                    installer.install(wrapper, config)
                self.assertFalse(wrapper.exists())
                self.assertEqual((binary / "llmjury").resolve(), original.resolve())
                installer.install(wrapper, config)
                self.assertEqual((binary / "llmjury").resolve(), wrapper.resolve())

    def test_interrupt_immediately_after_wrapper_publish_can_be_retried(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary, original, config = self.make_installation(Path(temporary))
            wrapper = binary / "local-council"
            real_replace = Path.replace
            def interrupt_after_publish(path, target):
                result = real_replace(path, target)
                if Path(target) == wrapper:
                    raise KeyboardInterrupt()
                return result
            with mock.patch.object(Path, "replace", interrupt_after_publish), self.assertRaises(KeyboardInterrupt):
                installer.install(wrapper, config)
            self.assertFalse(wrapper.exists())
            self.assertEqual((binary / "llmjury").resolve(), original.resolve())
            installer.install(wrapper, config)
            self.assertEqual((binary / "llmjury").resolve(), wrapper.resolve())

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

    def test_native_cli_abbreviations_keep_explicit_choices(self):
        args = ["solve", "--ba=ollama", "--mo=mine", "--num", "4096", "--frontier-ba", "codex"]
        self.assertEqual(council.optimized_options(args), args)
        self.assertIn(council.MODELS, council.optimized_options(["solve", "--ba", "ollama"]))

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
