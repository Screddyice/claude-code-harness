#!/usr/bin/env python3
"""Install smaller jury defaults without changing services or memory policy."""
import json
import os
from pathlib import Path
import shutil


def main():
    os.umask(0o077)
    home = Path.home()
    wrapper = home / ".local/bin/local-council"
    config = home / ".config/llmjury/local-council.json"
    clients = json.loads(config.read_text()) if config.exists() else {}
    for name in ("llmjury", "jury"):
        client = wrapper.parent / name
        if not client.exists():
            continue
        if client.is_symlink() and client.resolve() == wrapper.resolve():
            if not Path(clients.get(name, "")).is_file():
                raise SystemExit(f"original {name} path is missing")
        elif client.is_symlink():
            clients[name] = str(client.resolve())
        else:
            raise SystemExit(f"refusing to overwrite existing regular file {client}")
    if not clients:
        raise SystemExit("install llmjury first")
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    config.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copyfile(Path(__file__).with_name("local-council.py"), wrapper)
    wrapper.chmod(0o755)
    config.write_text(json.dumps(clients, indent=2) + "\n")
    for name in clients:
        client = wrapper.parent / name
        client.unlink(missing_ok=True)
        client.symlink_to(wrapper)
    print("Local council: Qwen 4B + Phi 3.8B, 8192 context, verified Codex fallback.")
    print("Original executables retained. No service or memory-policy changes.")


if __name__ == "__main__":
    main()
