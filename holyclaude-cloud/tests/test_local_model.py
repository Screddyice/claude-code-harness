"""Unit tests for the local-model overflow feature.

When the session/cloud fleet is saturated and ready tasks remain, legion spawns
EXTRA workers backed by an on-device model (Qwen via the backdoor router on
:8083) instead of idling. Coverage:

  - config: [local_model] parses + defaults when absent
  - routing.is_simple: which overflow tasks are eligible for the local model
  - governor.local_model_slots / local_model_available: overflow capacity + preflight
  - cli._select_local_model: default vs coder model selection
  - dispatch.spawn_local: --model + ANTHROPIC_BASE_URL injection for local-model
  - cmd_reconcile: a failed local-model task re-dispatches to the real model
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from lib import config, dispatch, governor, routing, state
from lib.config import DispatchConfig, LegionConfig, LocalModelConfig, ReconcilerConfig, ReviewConfig
from lib.state import RunState, Task


# ---------------------------------------------------------------------------
# config parsing
# ---------------------------------------------------------------------------

def test_config_defaults_when_section_absent(tmp_path):
    cfg_path = tmp_path / "legion.toml"
    cfg_path.write_text("[swarm]\nmax_workers = 3\n")
    cfg = config.load(cfg_path)
    lm = cfg.local_model
    assert lm.enabled is True
    assert lm.max_workers == 2
    assert lm.base_url == "http://localhost:8083"
    assert lm.default_model == "qwen3.5:4b-64k"
    assert lm.coder_model == ""
    assert lm.offload == "simple"
    assert lm.redispatch_to_real_model is True


def test_config_parses_local_model_section(tmp_path):
    cfg_path = tmp_path / "legion.toml"
    cfg_path.write_text(
        "[local_model]\n"
        "enabled = false\n"
        "max_workers = 4\n"
        'default_model = "qwen3.5:9b-64k"\n'
        'coder_model = "qwen-coder"\n'
        'offload = "any"\n'
        "redispatch_to_real_model = false\n"
    )
    lm = config.load(cfg_path).local_model
    assert lm.enabled is False
    assert lm.max_workers == 4
    assert lm.default_model == "qwen3.5:9b-64k"
    assert lm.coder_model == "qwen-coder"
    assert lm.offload == "any"
    assert lm.redispatch_to_real_model is False


# ---------------------------------------------------------------------------
# routing.is_simple
# ---------------------------------------------------------------------------

def _disp() -> DispatchConfig:
    return DispatchConfig()  # local_file_threshold=5, cloud_minutes_threshold=5


def test_is_simple_trivial_task():
    t = Task(id="A", title="tweak", spec="", estimated_minutes=2, files_touched=["a.py"])
    assert routing.is_simple(t, _disp()) is True


def test_is_simple_small_task():
    t = Task(id="A", title="small", spec="", estimated_minutes=4, files_touched=["a.py", "b.py"])
    assert routing.is_simple(t, _disp()) is True


def test_is_not_simple_large_task():
    t = Task(id="A", title="big refactor", spec="", estimated_minutes=20,
             files_touched=[f"f{i}.py" for i in range(8)])
    assert routing.is_simple(t, _disp()) is False


def test_is_not_simple_browser_task():
    t = Task(id="A", title="playwright browser test", spec="scrape the page",
             estimated_minutes=2, files_touched=["a.py"])
    assert routing.is_simple(t, _disp()) is False


def test_is_not_simple_always_cloud_pattern():
    # "scrape" is in the default always_cloud_patterns
    t = Task(id="A", title="scrape vendor portal", spec="", estimated_minutes=2,
             files_touched=["a.py"])
    assert routing.is_simple(t, _disp()) is False


# ---------------------------------------------------------------------------
# governor.local_model_slots / local_model_available
# ---------------------------------------------------------------------------

def _run_state(*tasks: Task) -> RunState:
    return RunState(repo_url="r", base_branch="main", started_at=0.0,
                    tasks={t.id: t for t in tasks})


def _cfg(**lm_kwargs) -> LegionConfig:
    cfg = LegionConfig()
    cfg.local_model = LocalModelConfig(**lm_kwargs)
    return cfg


def test_local_model_slots_full_when_none_in_flight():
    s = _run_state(Task(id="A", title="", spec="", status="pending"))
    assert governor.local_model_slots(s, _cfg(max_workers=2)) == 2


def test_local_model_slots_subtracts_in_flight():
    s = _run_state(
        Task(id="A", title="", spec="", status="in_flight", target="local-model"),
        Task(id="B", title="", spec="", status="in_flight", target="cloud"),
    )
    # one local-model in flight, cloud doesn't count
    assert governor.local_model_slots(s, _cfg(max_workers=2)) == 1


def test_local_model_slots_floored_at_zero():
    s = _run_state(
        Task(id="A", title="", spec="", status="in_flight", target="local-model"),
        Task(id="B", title="", spec="", status="in_flight", target="local-model"),
        Task(id="C", title="", spec="", status="in_flight", target="local-model"),
    )
    assert governor.local_model_slots(s, _cfg(max_workers=2)) == 0


def test_local_model_slots_zero_when_disabled():
    s = _run_state(Task(id="A", title="", spec="", status="pending"))
    assert governor.local_model_slots(s, _cfg(enabled=False, max_workers=5)) == 0


def test_local_model_available_false_when_disabled():
    assert governor.local_model_available(_cfg(enabled=False)) is False


def test_local_model_available_false_when_router_unreachable():
    # nothing listening on this port → fast failure, not a hang
    cfg = _cfg(enabled=True, base_url="http://127.0.0.1:1")
    assert governor.local_model_available(cfg) is False


# ---------------------------------------------------------------------------
# cli._select_local_model
# ---------------------------------------------------------------------------

def test_select_local_model_default_when_no_coder():
    from lib.cli import _select_local_model
    lm = LocalModelConfig(default_model="qwen3.5:4b-64k", coder_model="")
    t = Task(id="A", title="", spec="", files_touched=["a.py"])
    assert _select_local_model(t, lm) == "qwen3.5:4b-64k"


def test_select_local_model_coder_for_code_files():
    from lib.cli import _select_local_model
    lm = LocalModelConfig(default_model="qwen3.5:4b-64k", coder_model="qwen-coder")
    t = Task(id="A", title="", spec="", files_touched=["src/app.ts"])
    assert _select_local_model(t, lm) == "qwen-coder"


def test_select_local_model_default_for_non_code_files():
    from lib.cli import _select_local_model
    lm = LocalModelConfig(default_model="qwen3.5:4b-64k", coder_model="qwen-coder")
    t = Task(id="A", title="", spec="", files_touched=["README.md"])
    assert _select_local_model(t, lm) == "qwen3.5:4b-64k"


# ---------------------------------------------------------------------------
# dispatch.spawn_local — model + base_url injection
# ---------------------------------------------------------------------------

def _spawn_local_capture(tmp_path, monkeypatch, *, model=None, base_url=None):
    """Run spawn_local with subprocess mocked; return (cmd, env) handed to Popen."""
    monkeypatch.chdir(tmp_path)
    captured = {}

    def _fake_popen(cmd, **kw):
        captured["cmd"] = cmd
        captured["env"] = kw.get("env", {})
        m = MagicMock()
        m.pid = 4242
        return m

    monkeypatch.setattr(dispatch.subprocess, "run",
                        MagicMock(return_value=MagicMock(returncode=0, stdout="", stderr="")))
    monkeypatch.setattr(dispatch.subprocess, "Popen", _fake_popen)
    monkeypatch.setattr("shutil.which", lambda _x: "/usr/bin/" + _x)

    task = Task(id="T-1", title="t", spec="s")
    meta = dispatch.spawn_local(task, "main", "legion/", model=model, base_url=base_url)
    return captured, meta


def test_spawn_local_no_model_is_plain_local(tmp_path, monkeypatch):
    # Scrub any inherited router var so we test what spawn_local itself sets.
    monkeypatch.delenv("ANTHROPIC_BASE_URL", raising=False)
    captured, meta = _spawn_local_capture(tmp_path, monkeypatch)
    assert "--model" not in captured["cmd"]
    # Without a model, spawn_local must NOT point the worker at the router.
    assert "ANTHROPIC_BASE_URL" not in captured["env"]
    assert meta["target"] == "local"
    assert meta["model"] is None


def test_spawn_local_with_model_injects_flag_and_base_url(tmp_path, monkeypatch):
    captured, meta = _spawn_local_capture(
        tmp_path, monkeypatch, model="qwen3.5:4b-64k", base_url="http://localhost:8083"
    )
    cmd = captured["cmd"]
    assert "--model" in cmd
    assert cmd[cmd.index("--model") + 1] == "qwen3.5:4b-64k"
    assert captured["env"]["ANTHROPIC_BASE_URL"] == "http://localhost:8083"
    assert "ANTHROPIC_API_KEY" not in captured["env"]
    assert meta["target"] == "local-model"
    assert meta["model"] == "qwen3.5:4b-64k"


# ---------------------------------------------------------------------------
# cmd_reconcile — failed local-model task re-dispatches to the real model
# ---------------------------------------------------------------------------

def _reconcile_cfg(redispatch=True) -> LegionConfig:
    cfg = LegionConfig()
    cfg.reconciler = ReconcilerConfig(mediator_max_retries=2)
    cfg.review = ReviewConfig(enabled=False)
    cfg.local_model = LocalModelConfig(redispatch_to_real_model=redispatch)
    return cfg


def _run_reconcile(tmp_path, run: RunState, cfg: LegionConfig) -> RunState:
    from lib.cli import cmd_reconcile
    legion_dir = tmp_path / ".legion"
    legion_dir.mkdir(parents=True, exist_ok=True)
    state_file = legion_dir / "state.json"
    state_file.write_text(json.dumps(run.to_dict()))
    lock_file = legion_dir / "state.lock"
    lock_file.touch()

    orig = (state.STATE_PATH, state.LOCK_PATH, state.LEGION_DIR)
    state.STATE_PATH, state.LOCK_PATH, state.LEGION_DIR = state_file, lock_file, legion_dir
    try:
        with patch("lib.cli.load_config", return_value=cfg), \
             patch("lib.cli.print", side_effect=lambda *a, **k: None), \
             patch("lib.cli.reconciler.auto_heal", return_value=[]), \
             patch("lib.cli.reconciler.check_ci", return_value="fail"), \
             patch("lib.cli.reconciler.fetch_ci_failure", return_value="lint failed"):
            cmd_reconcile(MagicMock())
    finally:
        state.STATE_PATH, state.LOCK_PATH, state.LEGION_DIR = orig
    return RunState.from_dict(json.loads(state_file.read_text()))


def _shipped_local_model_task() -> Task:
    return Task(id="T-1", title="t", spec="do it", status="shipped",
                pr_url="https://github.com/x/y/pull/1", target="local-model",
                mediator_attempts=0)


def test_failed_local_model_task_forced_to_real_model(tmp_path):
    run = _run_state(_shipped_local_model_task())
    updated = _run_reconcile(tmp_path, run, _reconcile_cfg(redispatch=True))
    t = updated.tasks["T-1"]
    assert t.status == "pending"            # re-dispatched
    assert t.force_real_model is True       # pinned to a real model now


def test_failed_local_model_task_not_forced_when_disabled(tmp_path):
    run = _run_state(_shipped_local_model_task())
    updated = _run_reconcile(tmp_path, run, _reconcile_cfg(redispatch=False))
    t = updated.tasks["T-1"]
    assert t.status == "pending"
    assert t.force_real_model is False


def test_failed_cloud_task_not_marked_force_real_model(tmp_path):
    task = _shipped_local_model_task()
    task.target = "cloud"
    run = _run_state(task)
    updated = _run_reconcile(tmp_path, run, _reconcile_cfg(redispatch=True))
    assert updated.tasks["T-1"].force_real_model is False
