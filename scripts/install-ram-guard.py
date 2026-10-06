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
    parser.add_argument("--emergency-stop", action="store_true", help="stop local Ollama model runners at 95%%")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("this installer requires macOS")
    os.umask(0o077)
    home = Path.home()
    destination = home / ".local/bin/ram-guard"
    wrapper = home / ".local/bin/ram-guard-client"
    state = home / ".local/state/ram-guard"
    agent = home / "Library/LaunchAgents/com.screddy.ram-guard.plist"
    for directory in (destination.parent, state, agent.parent):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    clients_file = state / "clients.json"
    clients = json.loads(clients_file.read_text()) if clients_file.exists() else {}
    if args.emergency_stop and args.mode != "block":
        parser.error("emergency stop requires block mode")
    binary = shutil.which("ollama")
    if args.emergency_stop and not binary:
        parser.error("cannot find Ollama executable")
    if args.mode == "block":
        for name in ("llmjury", "jury", "qwen"):
            client = destination.parent / name
            if not client.exists():
                continue
            if client.is_symlink() and client.resolve() == wrapper.resolve():
                if not Path(clients.get(name, "")).is_file():
                    parser.error(f"original {name} path is missing")
            elif client.is_symlink():
                clients[name] = str(client.resolve())
            else:
                parser.error(f"refusing to overwrite existing regular file {client}")
    label = "com.screddy.ram-guard"
    domain = f"gui/{os.getuid()}"
    # Touch only this independent monitor's lifecycle, never Ollama or Backdoor.
    loaded = subprocess.run(["launchctl", "print", f"{domain}/{label}"], capture_output=True).returncode == 0
    if loaded:
        subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], check=True)
    shutil.copyfile(Path(__file__).with_name("ram-guard.py"), destination)
    destination.chmod(0o755)
    if args.mode == "block":
        shutil.copyfile(Path(__file__).with_name("ram-guard-client.py"), wrapper)
        wrapper.chmod(0o755)
        clients_file.write_text(json.dumps(clients, indent=2) + "\n")
        for name in clients:
            client = destination.parent / name
            client.unlink(missing_ok=True)
            client.symlink_to(wrapper)
    (state / "config.json").write_text(json.dumps({**vars(args), "ollama_binary": str(Path(binary).resolve()) if binary else None}, indent=2) + "\n")
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
    status = subprocess.run(["launchctl", "print", f"{domain}/{label}"], check=True, capture_output=True, text=True)
    # launchctl prints inherited credentials; emit only lifecycle fields.
    for line in status.stdout.splitlines():
        if line.strip().startswith(("state =", "pid =", "last exit code =")):
            print(line.strip())
    print(f"Installed: block 94%, emergency 95% ({args.emergency_stop}), recovery below 90%, 2-second checks, {args.mode}, {args.metric}.")


if __name__ == "__main__":
    main()
