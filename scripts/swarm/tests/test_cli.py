import importlib.util
import json
import sys
from pathlib import Path

import pytest

SWARM_PY = Path(__file__).resolve().parents[1] / "swarm.py"
spec = importlib.util.spec_from_file_location("swarm_cli", SWARM_PY)
swarm_cli = importlib.util.module_from_spec(spec)
sys.modules["swarm_cli"] = swarm_cli
spec.loader.exec_module(swarm_cli)


def test_run_requires_tasks_flag(capsys):
    with pytest.raises(SystemExit):
        swarm_cli.main(["run"])


def test_run_bad_tasks_file(tmp_path):
    bad = tmp_path / "tasks.json"
    bad.write_text("{not json")
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["run", "--tasks", str(bad)])
    assert "cannot read tasks file" in str(exc.value)


def test_run_invalid_task_shape(tmp_path):
    bad = tmp_path / "tasks.json"
    bad.write_text(json.dumps({"tasks": [{"id": "x!", "task": "y"}]}))
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["run", "--tasks", str(bad)])
    assert "invalid task id" in str(exc.value)


def test_run_passes_options_and_exit_code(tmp_path, monkeypatch, capsys):
    tasks_file = tmp_path / "tasks.json"
    tasks_file.write_text(json.dumps({"tasks": [{"id": "t1", "task": "x"}]}))
    captured = {}

    class StubEngine:
        def __init__(self, workspace, tasks, **kw):
            captured["workspace"] = workspace
            captured["tasks"] = tasks
            captured["kw"] = kw

        def run(self):
            return 2, {"run_id": "r", "workspace": "w", "base_sha": "abc",
                       "counts": {"completed": 1, "blocked": 1,
                                  "provider_limited": 0, "provider_unavailable": 0},
                       "tasks": []}

    monkeypatch.setattr(swarm_cli, "SwarmEngine", StubEngine)
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["run", "--workspace", str(tmp_path), "--tasks", str(tasks_file),
                        "--via", "claude", "--max-parallel", "2", "--max-total", "3",
                        "--fallback", "--allow-dirty", "--json"])
    assert exc.value.code == 2
    assert captured["tasks"][0]["via"] == "claude"
    assert captured["kw"]["max_parallel"] == 2
    assert captured["kw"]["max_total"] == 3
    assert captured["kw"]["fallback"] is True
    assert captured["kw"]["allow_dirty"] is True
    report = json.loads(capsys.readouterr().out)
    assert report["run_id"] == "r"


def test_status_missing_run_errors():
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["status", "no-such-run"])
    assert "no manifest" in str(exc.value)


def test_clean_missing_run_errors():
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["clean", "no-such-run"])
    assert "no manifest" in str(exc.value)


def test_clean_refusal_exits_one(monkeypatch, capsys):
    monkeypatch.setattr(swarm_cli.engine, "clean",
                        lambda run_id, force=False: ([], ["t1 (b): unfolded"]))
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["clean", "some-run"])
    assert exc.value.code == 1
    err = capsys.readouterr().err
    assert "refused" in err and "--force" in err


def test_clean_success_exits_zero(monkeypatch, capsys):
    monkeypatch.setattr(swarm_cli.engine, "clean",
                        lambda run_id, force=False: (["t1"], []))
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["clean", "some-run"])
    assert exc.value.code == 0
    assert "cleaned: t1" in capsys.readouterr().out
