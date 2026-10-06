#!/usr/bin/env python3
"""Install smaller jury defaults without changing services or memory policy."""
import json
import os
from pathlib import Path
import shutil
import fcntl
import tempfile

CLIENT_NAMES = ("llmjury", "jury")


def main():
    os.umask(0o077)
    home = Path.home()
    wrapper = home / ".local/bin/local-council"
    config = home / ".config/llmjury/local-council.json"
    config.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (config.parent / "install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        install(wrapper, config)


def install(wrapper, config):
    clients = json.loads(config.read_text()) if config.exists() else {}
    if not isinstance(clients, dict) or any(name not in CLIENT_NAMES or not isinstance(original, str) for name, original in clients.items()):
        raise SystemExit("invalid original CLI configuration")
    if wrapper.is_symlink():
        raise SystemExit(f"refusing to overwrite wrapper symlink {wrapper}")
    owned_wrapper = bool(clients) and any(
        (wrapper.parent / name).is_symlink() and (wrapper.parent / name).resolve() == wrapper.resolve()
        for name in CLIENT_NAMES
    )
    wrapper_existed = wrapper.exists()
    if wrapper_existed and (not wrapper.is_file() or not owned_wrapper):
        raise SystemExit(f"refusing to overwrite existing unowned wrapper {wrapper}")
    for name in CLIENT_NAMES:
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
    for name, original in clients.items():
        if not isinstance(original, str) or not Path(original).is_absolute() or not Path(original).is_file() or Path(original).resolve() == wrapper.resolve():
            raise SystemExit(f"original {name} path is missing or recursive")
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    # Stage before publishing; failed writes leave the installed CLI usable.
    with tempfile.TemporaryDirectory(dir=wrapper.parent) as binary_stage, tempfile.TemporaryDirectory(dir=config.parent) as config_stage:
        staged_wrapper = Path(binary_stage) / wrapper.name
        staged_config = Path(config_stage) / config.name
        shutil.copyfile(Path(__file__).with_name("local-council.py"), staged_wrapper)
        staged_wrapper.chmod(0o755)
        staged_config.write_text(json.dumps(clients, indent=2) + "\n")
        for name in clients:
            (Path(binary_stage) / name).symlink_to(wrapper)
        # Both old and new wrappers understand this config. Publish it first.
        staged_config.replace(config)
        staged_wrapper.replace(wrapper)
        try:
            for name in clients:
                (Path(binary_stage) / name).replace(wrapper.parent / name)
        except (OSError, KeyboardInterrupt):
            if not wrapper_existed and not any(
                (wrapper.parent / name).is_symlink() and (wrapper.parent / name).resolve() == wrapper.resolve()
                for name in clients
            ):
                wrapper.unlink()
            raise
    print("Local council: Qwen 4B + Phi 3.8B, 8192 context, verified Codex fallback.")
    print("Original executables retained. No service or memory-policy changes.")


if __name__ == "__main__":
    main()
