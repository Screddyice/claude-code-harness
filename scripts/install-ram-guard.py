#!/usr/bin/env python3
"""Install the independent macOS RAM monitor with an explicit response policy."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=("alert", "block"))
    parser.add_argument("--metric", required=True, choices=("occupied", "memory-used"))
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("this installer requires macOS")
    os.umask(0o077)
    home = Path.home()
    destination = home / ".local/bin/ram-guard"
    state = home / ".local/state/ram-guard"
    agent = home / "Library/LaunchAgents/com.screddy.ram-guard.plist"
    for directory in (destination.parent, state, agent.parent):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    label = "com.screddy.ram-guard"
    domain = f"gui/{os.getuid()}"
    # Touch only this independent monitor's lifecycle, never Ollama or Backdoor.
    loaded = subprocess.run(["launchctl", "print", f"{domain}/{label}"], capture_output=True).returncode == 0
    if loaded:
        subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], check=True)
    shutil.copyfile(Path(__file__).with_name("ram-guard.py"), destination)
    destination.chmod(0o755)
    (state / "config.json").write_text(json.dumps(vars(args), indent=2) + "\n")
    # Resolve Python now: launchd does not inherit an interactive shell's PATH.
    agent.write_bytes(plistlib.dumps({
        "Label": label, "ProgramArguments": [sys.executable, str(destination), "watch"],
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
        "ProcessType": "Background", "Umask": 0o077,
        "StandardOutPath": str(state / "launchd.log"),
        "StandardErrorPath": str(state / "launchd.log"),
    }))
    subprocess.run([sys.executable, str(destination), "once", "--quiet"], check=True)
    subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
    subprocess.run(["launchctl", "print", f"{domain}/{label}"], check=True)
    print(f"Installed: 94% trigger, recovery below 90%, 5-second checks, {args.mode}, {args.metric}.")


if __name__ == "__main__":
    main()
