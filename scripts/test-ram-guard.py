#!/usr/bin/env python3
"""Offline guard boundaries, cache accounting, hysteresis and probe failures."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ram_guard", Path(__file__).with_name("ram-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def snapshot(free=5, speculative=1, anonymous=30, purgeable=2, wired=10, compressed=5, page=16384):
    return (f"Mach Virtual Memory Statistics: (page size of {page} bytes)\n"
            f"Pages free: {free}.\nPages speculative: {speculative}.\n"
            f"Pages active: {anonymous + 19}.\nPages inactive: 20.\nFile-backed pages: 40.\nPages purgeable: {purgeable}.\n"
            f"Pages wired down: {wired}.\nPages occupied by compressor: {compressed}.\n")


class GuardTests(unittest.TestCase):
    def test_trigger_exact_boundary(self):
        self.assertFalse(guard.transition(False, 9399, 10000))
        self.assertTrue(guard.transition(False, 9400, 10000))
        self.assertTrue(guard.transition(False, 9500, 10000))

    def test_recovery_hysteresis(self):
        self.assertTrue(guard.transition(True, 9300, 10000))
        self.assertTrue(guard.transition(True, 9000, 10000))
        self.assertFalse(guard.transition(True, 8999, 10000))
        self.assertFalse(guard.transition(False, 9300, 10000))

    def test_distinguish_cache_from_memory_used(self):
        occupied = guard.memory_snapshot(snapshot(), 100 * 16384, "occupied")
        used = guard.memory_snapshot(snapshot(), 100 * 16384, "memory-used")
        self.assertEqual(occupied["usage_percent"], 94)
        self.assertEqual(used["usage_percent"], 43)
        self.assertTrue(guard.transition(False, occupied["used_bytes"], occupied["total_bytes"]))
        self.assertFalse(guard.transition(False, used["used_bytes"], used["total_bytes"]))

    def test_actual_page_size(self):
        for page in (4096, 16384):
            with self.subTest(page=page):
                self.assertEqual(guard.memory_snapshot(snapshot(page=page), 100 * page, "occupied")["usage_percent"], 94)

    def test_incomplete_or_impossible_probe_refused(self):
        for vm, total in (("Pages free: 5.", 100), (snapshot(), 0), (snapshot(anonymous=200), 100 * 16384)):
            with self.subTest(vm=vm, total=total), self.assertRaises(ValueError):
                guard.memory_snapshot(vm, total, "occupied")

    def test_fresh_check_catches_crossing_before_monitor(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            guard.write_json(directory / "status.json", {"active": False})
            with patch.object(guard, "probe", return_value={"used_bytes": 94, "total_bytes": 100, "usage_percent": 94}):
                self.assertEqual(guard.check(directory, {"mode": "block", "metric": "occupied"}), 2)

    def test_alert_mode_does_not_block(self):
        with patch.object(guard, "probe", side_effect=AssertionError("no admission gate")):
            self.assertEqual(guard.check(Path("unused"), {"mode": "alert"}), 0)

    def test_probe_failure_blocks_and_recovers(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(guard, "notify") as notify:
            directory = Path(temporary)
            config = {"mode": "block", "metric": "occupied"}
            with patch.object(guard, "probe", side_effect=subprocess.TimeoutExpired("vm_stat", 3)):
                self.assertTrue(guard.sample(directory, config)["blocked"])
                guard.sample(directory, config)
                self.assertEqual(guard.check(directory, config), 2)
            self.assertEqual(notify.call_count, 1)
            with patch.object(guard, "probe", return_value={"used_bytes": 80, "total_bytes": 100, "usage_percent": 80}):
                self.assertFalse(guard.sample(directory, config)["blocked"])
            self.assertEqual(notify.call_count, 2)

    def test_crossing_alert_is_once_until_recovery(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(guard, "notify") as notify:
            directory = Path(temporary)
            config = {"mode": "block", "metric": "occupied"}
            with patch.object(guard, "probe", return_value={"used_bytes": 94, "total_bytes": 100, "usage_percent": 94}), patch.object(guard.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "PID RSS COMM\n7 150 /app\n8 250 /other\n")):
                self.assertTrue(guard.sample(directory, config)["blocked"])
                self.assertTrue(guard.sample(directory, config)["blocked"])
            self.assertEqual(notify.call_count, 1)
            self.assertIn("8 250 /other", (directory / "largest-processes.txt").read_text())
            with patch.object(guard, "probe", return_value={"used_bytes": 89, "total_bytes": 100, "usage_percent": 89}):
                self.assertFalse(guard.sample(directory, config)["blocked"])
            self.assertEqual(notify.call_count, 2)
            self.assertFalse(json.loads((directory / "status.json").read_text())["active"])


if __name__ == "__main__":
    unittest.main()
