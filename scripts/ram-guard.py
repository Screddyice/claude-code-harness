#!/usr/bin/env python3
"""macOS RAM threshold monitor; does not signal or unload any process."""
import argparse
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import subprocess
import time

TRIGGER = 94
RECOVERY = 90
STATE_DIR = Path.home() / ".local/state/ram-guard"


def memory_snapshot(vm_stat, total, metric):
    """Count physical pages, not memory_pressure's reclaimability percentage."""
    size = re.search(r"page size of (\d+) bytes", vm_stat)
    counts = dict(re.findall(r"^([^:\n]+):\s*(\d+)\.\s*$", vm_stat, re.M))
    required = ("Pages free", "Pages speculative", "Pages active", "Pages inactive",
                "File-backed pages", "Pages purgeable", "Pages wired down", "Pages occupied by compressor")
    if not size or int(size[1]) <= 0 or total <= 0 or any(k not in counts for k in required):
        raise ValueError("incomplete physical memory probe")
    page = int(size[1])
    values = {k: int(counts[k]) * page for k in required}
    occupied = total - values["Pages free"] - values["Pages speculative"]
    # Same formula as Stats 3.0.19 Modules/RAM/readers.swift. File cache is
    # reclaimable; compressor occupancy counts physical pages, not logical size.
    memory_used = (values["Pages active"] + values["Pages inactive"] + values["Pages speculative"]
                   + values["Pages wired down"] + values["Pages occupied by compressor"]
                   - values["Pages purgeable"] - values["File-backed pages"])
    if not 0 <= memory_used <= total or not 0 <= occupied <= total:
        raise ValueError("physical memory counters exceed RAM")
    used = occupied if metric == "occupied" else memory_used
    return {"total_bytes": total, "used_bytes": used, "usage_percent": used * 100 / total,
            "occupied_percent": occupied * 100 / total,
            "memory_used_percent": memory_used * 100 / total, "metric": metric}


def probe(metric):
    def read(args):
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=3).stdout
    return memory_snapshot(read(["/usr/bin/vm_stat"]),
                           int(read(["/usr/sbin/sysctl", "-n", "hw.memsize"]).strip()), metric)


def transition(active, used, total):
    """Use integer comparisons so exactly 94 percent triggers."""
    if used * 100 >= total * TRIGGER:
        return True
    if used * 100 < total * RECOVERY:
        return False
    return active


def read_json(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def notify(message):
    # Pass text as argv; process names and user input never become AppleScript.
    script = ('on run argv\n display notification (item 1 of argv) '
              'with title "RAM guard"\nend run')
    try:
        subprocess.run(["/usr/bin/osascript", "-e", script, message],
                       capture_output=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        logging.exception("desktop notification failed")


def sample(directory, config, alert=True):
    previous = read_json(directory / "status.json")
    now = {"sampled_at": time.time(), "trigger_percent": TRIGGER,
           "recovery_below_percent": RECOVERY, **config}
    try:
        now.update(probe(config["metric"]))
        now["active"] = transition(previous.get("active") is True,
                                   now["used_bytes"], now["total_bytes"])
        now["error"] = None
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        now.update(active=previous.get("active") is True, error=str(error))
    now["blocked"] = config["mode"] == "block" and (now["active"] or bool(now["error"]))
    old_state = (previous.get("active", False), bool(previous.get("error")))
    new_state = (now["active"], bool(now["error"]))
    write_json(directory / "status.json", now)
    if old_state != new_state:
        if now["error"]:
            message = "RAM probe failed; " + ("new local AI work is blocked." if now["blocked"] else "check the guard log.")
        elif now["active"]:
            message = f"RAM at {now['usage_percent']:.1f}% (94% limit). "
            message += "New local AI work is blocked." if now["blocked"] else "Close unused apps to free memory."
            # Only executable names, no command arguments that could contain secrets.
            try:
                output = subprocess.run(["/bin/ps", "-axo", "pid,rss,comm"],
                                        check=True, capture_output=True, text=True, timeout=3).stdout
                rows = sorted(output.splitlines()[1:], key=lambda row: int(row.split()[1]), reverse=True)
                (directory / "largest-processes.txt").write_text("PID RSS_KiB EXECUTABLE\n" + "\n".join(rows[:15]) + "\n")
            except (OSError, ValueError, IndexError, subprocess.SubprocessError):
                logging.exception("process snapshot failed")
        else:
            message = f"RAM guard recovered; usage {now['usage_percent']:.1f}%."
        logging.warning(message)
        if alert:
            notify(message)
    return now


def check(directory, config):
    if config["mode"] != "block":
        return 0
    # Probe afresh; a stopped monitor or stale healthy file cannot admit a load.
    try:
        current = probe(config["metric"])
        blocked = transition(read_json(directory / "status.json").get("active") is True,
                             current["used_bytes"], current["total_bytes"])
        if blocked:
            print(f"RAM guard: {current['usage_percent']:.1f}% usage; new local AI work blocked at 94%, resumes below 90%.")
        return 2 if blocked else 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"RAM guard: cannot read RAM; refusing new local AI work: {error}")
        return 2


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "once", "watch", "check"))
    parser.add_argument("--state-dir", type=Path, default=STATE_DIR)
    parser.add_argument("--quiet", action="store_true", help="suppress desktop alerts for a one-shot sample")
    args = parser.parse_args()
    directory = args.state_dir
    config = read_json(directory / "config.json")
    if config.get("mode") not in ("alert", "block") or config.get("metric") not in ("occupied", "memory-used"):
        parser.error("install with an explicit mode and metric first")
    if args.command == "status":
        print(json.dumps({"live": probe(config["metric"]), "config": config,
                          "monitor": read_json(directory / "status.json")}, indent=2))
        return 0
    if args.command == "check":
        return check(directory, config)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    handler = RotatingFileHandler(directory / "guard.log", maxBytes=256 * 1024, backupCount=2)
    logging.basicConfig(handlers=[handler], level=logging.INFO, format="%(asctime)s %(message)s")
    if args.command == "once":
        print(json.dumps(sample(directory, config, not args.quiet), indent=2))
        return 0
    logging.info("guard started: trigger=94%% recovery<90%% interval=5s mode=%s metric=%s", config["mode"], config["metric"])
    while True:
        sample(directory, config)
        time.sleep(5)


if __name__ == "__main__":
    raise SystemExit(main())
