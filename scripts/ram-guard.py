#!/usr/bin/env python3
"""macOS RAM admission guard with optional Ollama-runner emergency stop."""
import argparse
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time

TRIGGER = 94
RECOVERY = 90
EMERGENCY = 95
INTERVAL = 2
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


def runner_identity(pid, binary):
    """Pin UID, parent, start time and argv; only the configured Ollama runner."""
    try:
        result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "uid=", "-o", "ppid=",
                                 "-o", "lstart=", "-o", "command="],
                                capture_output=True, text=True, check=True, timeout=2)
        parts = result.stdout.split(None, 7)
        if len(parts) != 8 or int(parts[0]) != os.getuid():
            return None
        argv = shlex.split(parts[7])
        if len(argv) < 2 or argv[1] != "runner" or Path(argv[0]).resolve() != binary:
            return None
        parent = subprocess.run(["/bin/ps", "-p", parts[1], "-o", "uid=", "-o", "command="],
                                capture_output=True, text=True, check=True, timeout=2).stdout.split(None, 1)
        parent_argv = shlex.split(parent[1])
        if int(parent[0]) != os.getuid() or len(parent_argv) < 2 or parent_argv[1] != "serve" or Path(parent_argv[0]).resolve() != binary:
            return None
        return tuple(parts)
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def emergency_stop(config):
    """Stop verified model runners, leaving the Ollama server and router alone."""
    binary = Path(config["ollama_binary"]).resolve()
    result = subprocess.run(["/usr/bin/pgrep", "-u", str(os.getuid()), "-f", r"^/[^ ]*/ollama runner( |$)"],
                            capture_output=True, text=True, timeout=2)
    if result.returncode not in (0, 1):
        raise RuntimeError("cannot enumerate Ollama runners")
    identities = {int(raw): runner_identity(int(raw), binary) for raw in result.stdout.split()}
    targets = {pid: identity for pid, identity in identities.items() if identity}
    receipt = {"terminated_pids": [], "killed_pids": [], "remaining_runner_pids": [], "errors": []}
    for pid, identity in targets.items():
        if runner_identity(pid, binary) == identity:
            try:
                os.kill(pid, signal.SIGTERM)
                receipt["terminated_pids"].append(pid)
            except ProcessLookupError:
                pass
            except OSError as error:
                receipt["errors"].append(f"TERM {pid}: {error}")
    if targets:
        time.sleep(1)
    for pid, identity in targets.items():
        if runner_identity(pid, binary) == identity:
            try:
                os.kill(pid, signal.SIGKILL)
                receipt["killed_pids"].append(pid)
            except ProcessLookupError:
                pass
            except OSError as error:
                receipt["errors"].append(f"KILL {pid}: {error}")
    if receipt["killed_pids"]:
        time.sleep(0.2)
    receipt["remaining_runner_pids"] = [pid for pid, identity in targets.items() if runner_identity(pid, binary) == identity]
    return receipt


def sample(directory, config, alert=True):
    previous = read_json(directory / "status.json")
    now = {"sampled_at": time.time(), "trigger_percent": TRIGGER, "emergency_percent": EMERGENCY,
           "recovery_below_percent": RECOVERY, **config}
    try:
        now.update(probe(config["metric"]))
        now["active"] = transition(previous.get("active") is True,
                                   now["used_bytes"], now["total_bytes"])
        now["error"] = None
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        now.update(active=previous.get("active") is True, error=str(error))
    now["blocked"] = config["mode"] == "block" and (now["active"] or bool(now["error"]))
    now["emergency_attempted"] = previous.get("emergency_attempted", False) if now["active"] or now["error"] else False
    if now["emergency_attempted"]:
        now["emergency_receipt"] = previous.get("emergency_receipt")
    old_state = (previous.get("active", False), bool(previous.get("error")))
    new_state = (now["active"], bool(now["error"]))
    write_json(directory / "status.json", now)
    if (config.get("emergency_stop") and not now["error"] and not now["emergency_attempted"]
            and now["used_bytes"] * 100 >= now["total_bytes"] * EMERGENCY):
        # Publish before signalling. An interrupted/uncertain action is never
        # replayed on the next sample or daemon restart in this pressure episode.
        now["emergency_attempted"] = True
        write_json(directory / "status.json", now)
        try:
            now["emergency_receipt"] = emergency_stop(config)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            now["emergency_receipt"] = {"errors": [str(error)]}
        write_json(directory / "status.json", now)
        logging.warning("95%% emergency model-stop receipt: %s", now["emergency_receipt"])
        if alert:
            notify("RAM reached 95%. Emergency Ollama model stop attempted; see guard status for its result.")
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
    logging.info("guard started: block=94%% emergency=95%% recovery<90%% interval=2s mode=%s metric=%s", config["mode"], config["metric"])
    with (directory / "monitor.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            logging.error("another RAM monitor already owns the lock")
            return 1
        while True:
            sample(directory, config)
            time.sleep(INTERVAL)


if __name__ == "__main__":
    raise SystemExit(main())
