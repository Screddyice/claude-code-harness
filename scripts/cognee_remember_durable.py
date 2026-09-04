#!/usr/bin/env python3
"""Durable Cognee remember: journal, send, verify, re-send.

Cognee answers `remember` with 200 the moment the write is queued, then holds
it in process memory until the cognify pipeline reaches it. A restart in that
window (a watchdog restart, a redeploy, an OOM) drops the write, and the caller
never learns. On 2026-09-03 an evening of acknowledged writes vanished that way.

This wrapper makes the write durable from the client side:

  1. Journal the content locally under the outbox, keyed by its MD5.
  2. Send it through the plugin's own cognee-remember.sh.
  3. Verify: Cognee names every raw file `text_<md5(content)>.txt`, so one
     dataset listing shows whether the write landed. No search, no lock.
  4. If it has not landed in the wait window, leave it in the outbox and start a
     detached drainer that re-checks and re-sends until it does. Cognee
     de-duplicates by content hash (one row for two identical sends), so a
     re-send of something that did land later is harmless.

Only stdlib. Configuration is env, all optional:
  COGNEE_BASE_URL, COGNEE_API_KEY, COGNEE_PLUGIN_DATASET (read from
  ~/.cognee/.env when unset), COGNEE_OUTBOX (~/.cognee/outbox),
  COGNEE_REMEMBER_BIN (the plugin script), COGNEE_DURABLE_WAIT (60s),
  COGNEE_DURABLE_POLL (300s), COGNEE_DURABLE_RESEND (1200s),
  COGNEE_DURABLE_MAX_ATTEMPTS (6), COGNEE_DURABLE_MAX_AGE (21600s).
"""
from __future__ import annotations

import glob
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def _load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        os.environ.setdefault(k, v)


_load_env_file(Path.home() / ".cognee" / ".env")

BASE_URL = os.environ.get("COGNEE_BASE_URL", "http://127.0.0.1:8001").rstrip("/")
API_KEY = os.environ.get("COGNEE_API_KEY", "")
DATASET = os.environ.get("COGNEE_PLUGIN_DATASET", "agent_sessions")
OUTBOX = Path(os.environ.get("COGNEE_OUTBOX") or (Path.home() / ".cognee" / "outbox"))
WAIT = float(os.environ.get("COGNEE_DURABLE_WAIT", "60"))
POLL = float(os.environ.get("COGNEE_DURABLE_POLL", "300"))
RESEND = float(os.environ.get("COGNEE_DURABLE_RESEND", "1200"))
MAX_ATTEMPTS = int(os.environ.get("COGNEE_DURABLE_MAX_ATTEMPTS", "6"))
MAX_AGE = float(os.environ.get("COGNEE_DURABLE_MAX_AGE", "21600"))
HTTP_TIMEOUT = 20
# The dataset listing is the whole of agent_sessions in one response: 7,486 items
# and 3.9 MB took 58 s on 2026-09-04, and it grows with every write. At the 20 s
# used for small calls it always timed out, _landed_hashes returned None, and every
# write was reported unverifiable forever. Give the listing its own budget.
LIST_TIMEOUT = float(os.environ.get("COGNEE_DURABLE_LIST_TIMEOUT", "180"))


def _remember_bin() -> str:
    explicit = os.environ.get("COGNEE_REMEMBER_BIN")
    if explicit:
        return explicit
    pattern = str(Path.home() / ".claude/plugins/cache/cognee/cognee-memory/*/scripts/cognee-remember.sh")
    found = sorted(glob.glob(pattern))
    if not found:
        sys.exit("cognee-remember.sh not found; set COGNEE_REMEMBER_BIN")
    return found[-1]


def _get(path: str, timeout: float = HTTP_TIMEOUT):
    req = urllib.request.Request(f"{BASE_URL}{path}", headers={"X-Api-Key": API_KEY})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8") or "null")


def _dataset_id() -> str | None:
    try:
        rows = _get("/api/v1/datasets")
    except (urllib.error.URLError, ValueError, OSError):
        return None
    for row in rows or []:
        if row.get("name") == DATASET:
            return row.get("id")
    return None


def _landed_hashes(dataset_id: str) -> set[str] | None:
    """MD5s of every raw text file in the dataset, or None when Cognee is unreachable."""
    try:
        rows = _get(f"/api/v1/datasets/{dataset_id}/data", timeout=LIST_TIMEOUT)
    except (urllib.error.URLError, ValueError, OSError):
        return None
    if isinstance(rows, dict):
        rows = rows.get("data", [])
    out: set[str] = set()
    for row in rows or []:
        name = str(row.get("rawDataLocation") or row.get("raw_data_location") or "").rsplit("/", 1)[-1]
        if name.startswith("text_") and name.endswith(".txt"):
            out.add(name[5:-4])
    return out


def content_md5(content: str) -> str:
    """Stable key for the outbox entry. NOT the hash Cognee files the text under."""
    return hashlib.md5(content.rstrip("\n").encode("utf-8")).hexdigest()


def cognee_md5(sent_text: str) -> str:
    """The hash Cognee actually names the raw file with: `text_<md5>.txt` over the
    bytes it RECEIVES, trailing newline and all.

    The plugin does not strip a trailing newline, contrary to what this module
    assumed until 2026-09-04. `_send` transmits `content_path.read_text()`, so any
    content ending in a newline - every `--file` and every heredoc - hashed one way
    here and another way in Cognee, the expected filename never appeared in the
    listing, and the write was resent until it was abandoned. The data had landed
    each time. Hash exactly what `_send` transmits, and nothing else."""
    return hashlib.md5(sent_text.encode("utf-8")).hexdigest()


def _send(content_path: Path, node_set: str) -> tuple[bool, str]:
    cmd = [_remember_bin(), content_path.read_text(), "--node-set", node_set]
    env = dict(os.environ, COGNEE_REMEMBER_WAIT_SECONDS="0")
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=300, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    ok = p.returncode == 0 and '"ok": true' in p.stdout.replace(" ", "").replace('"ok":true', '"ok": true')
    return ok, (p.stdout + p.stderr).strip()[-400:]


def _entry_paths(md5: str) -> tuple[Path, Path]:
    return OUTBOX / f"{md5}.txt", OUTBOX / f"{md5}.json"


def _journal(content: str, node_set: str) -> str:
    OUTBOX.mkdir(parents=True, exist_ok=True)
    md5 = content_md5(content)
    txt, meta = _entry_paths(md5)
    if not txt.exists():
        txt.write_text(content)
    if not meta.exists():
        meta.write_text(json.dumps({"node_set": node_set, "dataset": DATASET, "first_sent": 0, "last_sent": 0, "attempts": 0}))
    return md5


def _load_meta(md5: str) -> dict:
    return json.loads(_entry_paths(md5)[1].read_text())


def _save_meta(md5: str, meta: dict) -> None:
    _entry_paths(md5)[1].write_text(json.dumps(meta))


def _clear(md5: str) -> None:
    for p in _entry_paths(md5):
        try:
            p.unlink()
        except FileNotFoundError:
            pass


def _attempt(md5: str) -> tuple[bool, str]:
    meta = _load_meta(md5)
    ok, detail = _send(_entry_paths(md5)[0], meta["node_set"])
    now = time.time()
    meta["attempts"] += 1
    meta["last_sent"] = now
    meta["first_sent"] = meta["first_sent"] or now
    meta["last_result"] = detail
    _save_meta(md5, meta)
    return ok, detail


def _verify(md5: str) -> bool | None:
    """True landed, False not yet, None Cognee unreachable.

    `md5` keys the outbox entry; what Cognee stores is keyed by the transmitted
    bytes, so read the journal file back and hash that - it is byte-for-byte what
    `_send` uploads.
    """
    ds = _dataset_id()
    if ds is None:
        return None
    hashes = _landed_hashes(ds)
    if hashes is None:
        return None
    try:
        expected = cognee_md5(_entry_paths(md5)[0].read_text())
    except OSError:
        return None
    return expected in hashes or md5 in hashes


def _spawn_drainer() -> None:
    pidfile = OUTBOX / ".drain.pid"
    try:
        pid = int(pidfile.read_text())
        os.kill(pid, 0)
        return  # one already running
    except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError):
        pass
    log = open(OUTBOX / "drain.log", "a")
    p = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--drain"],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
    )
    pidfile.write_text(str(p.pid))


def remember(content: str, node_set: str) -> int:
    md5 = _journal(content, node_set)
    ok, detail = _attempt(md5)
    deadline = time.time() + WAIT
    landed: bool | None = False
    while True:
        landed = _verify(md5)
        if landed:
            break
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        time.sleep(min(5, max(0.5, remaining)))
    if landed:
        _clear(md5)
        print(json.dumps({"ok": True, "stored": True, "md5": md5}))
        return 0
    _spawn_drainer()
    print(json.dumps({"ok": ok, "stored": False, "queued": True, "md5": md5,
                      "outbox": str(OUTBOX), "detail": None if ok else detail,
                      "note": "not in the dataset yet; a detached drainer re-checks and re-sends until it lands"}))
    return 0


def drain(once: bool = False) -> int:
    OUTBOX.mkdir(parents=True, exist_ok=True)
    (OUTBOX / ".drain.pid").write_text(str(os.getpid()))
    started = time.time()
    while True:
        pending = sorted(p.stem for p in OUTBOX.glob("*.json"))
        if not pending:
            break
        ds = _dataset_id()
        hashes = _landed_hashes(ds) if ds else None
        for md5 in pending:
            meta = _load_meta(md5)
            # The outbox key hashes the content with any trailing newline stripped;
            # Cognee files it under the bytes it received. Compare on the sent bytes,
            # exactly as _verify does - checking the key here was the same bug twice.
            try:
                landed_key = cognee_md5(_entry_paths(md5)[0].read_text())
            except OSError:
                landed_key = md5
            if hashes is not None and (landed_key in hashes or md5 in hashes):
                _clear(md5)
                print(f"{time.strftime('%FT%TZ', time.gmtime())} landed {md5}", flush=True)
                continue
            age = time.time() - (meta["first_sent"] or time.time())
            if meta["attempts"] >= MAX_ATTEMPTS or age > MAX_AGE:
                print(f"{time.strftime('%FT%TZ', time.gmtime())} GIVING UP {md5} attempts={meta['attempts']} age={int(age)}s (left in outbox)", flush=True)
                meta["abandoned"] = True
                _save_meta(md5, meta)
                continue
            if hashes is not None and time.time() - meta["last_sent"] >= RESEND:
                ok, detail = _attempt(md5)
                print(f"{time.strftime('%FT%TZ', time.gmtime())} resent {md5} ok={ok} attempt={meta['attempts'] + 1}", flush=True)
        if once:
            break
        if all(_load_meta(m).get("abandoned") for m in pending if (OUTBOX / f"{m}.json").exists()):
            break
        if time.time() - started > MAX_AGE:
            break
        time.sleep(POLL)
    try:
        (OUTBOX / ".drain.pid").unlink()
    except FileNotFoundError:
        pass
    return 0


def status() -> int:
    OUTBOX.mkdir(parents=True, exist_ok=True)
    rows = []
    for meta_path in sorted(OUTBOX.glob("*.json")):
        meta = json.loads(meta_path.read_text())
        rows.append({"md5": meta_path.stem, **{k: meta.get(k) for k in ("node_set", "attempts", "first_sent", "last_sent", "abandoned")}})
    print(json.dumps({"outbox": str(OUTBOX), "pending": rows}, indent=2))
    return 0


def main(argv: list[str]) -> int:
    if "--drain" in argv:
        return drain(once="--once" in argv)
    if "--status" in argv:
        return status()
    node_set = "project_docs"
    content: str | None = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--node-set":
            node_set = argv[i + 1]
            i += 2
        elif a == "--file":
            content = Path(argv[i + 1]).read_text()
            i += 2
        elif a == "-":
            content = sys.stdin.read()
            i += 1
        else:
            content = a
            i += 1
    if not content or not content.strip():
        sys.exit("usage: cognee-remember-durable.sh <content>|--file <path>|- [--node-set user_context|project_docs|agent_actions]\n       cognee-remember-durable.sh --status | --drain [--once]")
    return remember(content, node_set)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
