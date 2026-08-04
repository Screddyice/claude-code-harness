import json
from pathlib import Path

import pytest

from conftest import FakeWorker, fail, git, make_tasks, ok_edit, ok_no_handoff

from swarmlib import engine as engine_mod
from swarmlib import gitops
from swarmlib.engine import SwarmEngine, SwarmError, load_tasks, overlap_warnings, preflight
from swarmlib.manifest import Manifest
from swarmlib.workers import WorkerResult


def build(repo, data, workers, **kw):
    tasks = load_tasks(data, kw.pop("via", "codex"))
    kw.setdefault("echo", lambda *_: None)
    return SwarmEngine(repo, tasks, workers=workers, **kw)


# -- load_tasks validation ----------------------------------------------

def test_load_tasks_rejects_bad_shapes():
    with pytest.raises(SwarmError, match="tasks file must be"):
        load_tasks({"nope": []}, "codex")
    with pytest.raises(SwarmError, match="no tasks"):
        load_tasks({"tasks": []}, "codex")
    with pytest.raises(SwarmError, match="invalid task id"):
        load_tasks({"tasks": [{"id": "bad id!", "task": "x"}]}, "codex")
    with pytest.raises(SwarmError, match="duplicate task id"):
        load_tasks({"tasks": [{"id": "a", "task": "x"}, {"id": "a", "task": "y"}]}, "codex")
    with pytest.raises(SwarmError, match="no task text"):
        load_tasks({"tasks": [{"id": "a", "task": "  "}]}, "codex")
    with pytest.raises(SwarmError, match="unknown provider"):
        load_tasks({"tasks": [{"id": "a", "task": "x", "via": "gemini"}]}, "codex")
    with pytest.raises(SwarmError, match="files must be"):
        load_tasks({"tasks": [{"id": "a", "task": "x", "files": "src/"}]}, "codex")


def test_load_tasks_applies_default_via():
    tasks = load_tasks({"tasks": [{"id": "a", "task": "x"}]}, "claude")
    assert tasks[0]["via"] == "claude"


def test_overlap_warnings():
    tasks = load_tasks(make_tasks(("a", "codex", ["src/x.py", "src/y.py"]),
                                  ("b", "codex", ["src/y.py"]),
                                  ("c", "codex", ["docs/z.md"])), "codex")
    warnings = overlap_warnings(tasks)
    assert len(warnings) == 1 and "src/y.py" in warnings[0]


# -- preflight -----------------------------------------------------------

def test_preflight_not_a_repo(tmp_path):
    errors = preflight(tmp_path, [], False, {"codex"})
    assert any("not a git repository" in e for e in errors)


def test_preflight_rs21(repo):
    git(["remote", "add", "origin", "git@github.com:teamnebula-ai/RS21-data.git"], repo)
    errors = preflight(repo, [], False, set())
    assert any("rs21" in e for e in errors)


def test_preflight_dirty_refused_and_allowed(repo):
    (repo / "README.md").write_text("dirty\n")
    errors = preflight(repo, [], False, set())
    assert any("uncommitted tracked changes" in e and "README.md" in e for e in errors)
    assert preflight(repo, [], True, set()) == []


def test_preflight_missing_cli(repo):
    errors = preflight(repo, [], False, {"codex"}, which=lambda name: None)
    assert any("codex CLI not found" in e for e in errors)


def test_run_refuses_on_preflight_error(repo):
    (repo / "README.md").write_text("dirty\n")
    eng = build(repo, make_tasks(("t1", "codex")), {"codex": FakeWorker("codex")})
    with pytest.raises(SwarmError, match="uncommitted"):
        eng.run()


# -- happy path ----------------------------------------------------------

def test_mixed_provider_run_completes(repo):
    workers = {
        "codex": FakeWorker("codex", default=ok_edit("codex.txt")),
        "claude": FakeWorker("claude", default=ok_edit("claude.txt")),
    }
    eng = build(repo, make_tasks(("c1", "codex"), ("a1", "claude")), workers)
    code, report = eng.run()
    assert code == 0
    assert report["counts"]["completed"] == 2
    for task in report["tasks"]:
        assert task["commit"] and task["changed_files"]
        assert gitops.branch_exists(repo, task["branch"])
        assert gitops.ahead_count(repo, task["branch"], report["base_sha"]) == 1
    manifest = Manifest.load(eng.run_id)
    assert manifest.data["status"] == "finished"


def test_completed_with_no_changes_has_no_commit(repo):
    def no_edit(worktree):
        from conftest import handoff
        return WorkerResult(0, "", "", 1.0, handoff())
    eng = build(repo, make_tasks(("t1", "codex")),
                {"codex": FakeWorker("codex", default=no_edit)})
    code, report = eng.run()
    assert code == 0 and report["tasks"][0]["commit"] is None


def test_blocked_handoff_stays_uncommitted(repo):
    eng = build(repo, make_tasks(("t1", "codex")),
                {"codex": FakeWorker("codex", default=ok_edit("partial.txt", status="blocked"))})
    code, report = eng.run()
    task = report["tasks"][0]
    assert code == 3 and task["status"] == "blocked"
    assert task["commit"] is None
    assert gitops.worktree_dirty(task["worktree"])  # preserved for inspection


def test_no_parseable_handoff_blocks(repo):
    eng = build(repo, make_tasks(("t1", "codex")),
                {"codex": FakeWorker("codex", default=ok_no_handoff())})
    code, report = eng.run()
    assert code == 3
    assert "no parseable handoff" in report["tasks"][0]["blockers"][0]


# -- breaker -------------------------------------------------------------

def test_limit_signature_trips_and_skips_queued(repo):
    workers = {
        "codex": FakeWorker("codex", behaviors={
            "task-c1": fail(stderr="usage limit reached", duration=5)}),
        "claude": FakeWorker("claude", default=ok_edit("claude.txt")),
    }
    eng = build(repo, make_tasks(("c1", "codex"), ("c2", "codex"), ("a1", "claude")),
                workers, max_parallel=1)
    code, report = eng.run()
    statuses = {t["id"]: t["status"] for t in report["tasks"]}
    assert statuses == {"c1": "provider_limited", "c2": "provider_limited",
                        "a1": "completed"}
    assert code == 2  # partial: claude side finished
    assert workers["codex"].calls == ["task-c1"]  # c2 never spawned


def test_two_fast_failures_trip_backstop(repo):
    workers = {"codex": FakeWorker("codex", default=fail(stderr="crash", duration=2))}
    eng = build(repo, make_tasks(("c1", "codex"), ("c2", "codex"), ("c3", "codex")),
                workers, max_parallel=1)
    code, report = eng.run()
    statuses = [t["status"] for t in report["tasks"]]
    assert statuses[0] == "blocked"                 # first fast failure: no trip yet
    assert statuses[1] == "provider_unavailable"    # second consecutive: trips
    assert statuses[2] == "provider_unavailable"    # queued task swept
    assert code == 3
    assert len(workers["codex"].calls) == 2


def test_single_slow_failure_never_trips(repo):
    workers = {"codex": FakeWorker("codex", behaviors={
        "task-c1": fail(stderr="slow crash", duration=120),
        "task-c2": ok_edit("ok.txt")})}
    eng = build(repo, make_tasks(("c1", "codex"), ("c2", "codex")), workers,
                max_parallel=1)
    code, report = eng.run()
    statuses = {t["id"]: t["status"] for t in report["tasks"]}
    assert statuses == {"c1": "blocked", "c2": "completed"}
    assert code == 2


def test_slow_failure_resets_fast_counter(repo):
    workers = {"codex": FakeWorker("codex", behaviors={
        "task-c1": fail(duration=2),
        "task-c2": fail(duration=120),
        "task-c3": fail(duration=2),
        "task-c4": ok_edit("ok.txt")})}
    eng = build(repo, make_tasks(("c1", "codex"), ("c2", "codex"),
                                 ("c3", "codex"), ("c4", "codex")),
                workers, max_parallel=1)
    code, report = eng.run()
    # fast, slow (resets), fast, success — breaker never trips
    assert all(t["status"] in ("blocked", "completed") for t in report["tasks"])
    assert len(workers["codex"].calls) == 4


# -- fallback ------------------------------------------------------------

def test_fallback_reroutes_failed_and_queued_tasks(repo):
    workers = {
        "codex": FakeWorker("codex", default=fail(stderr="usage limit", duration=3)),
        "claude": FakeWorker("claude", default=ok_edit("rescued.txt")),
    }
    eng = build(repo, make_tasks(("c1", "codex"), ("c2", "codex")), workers,
                max_parallel=1, fallback=True)
    code, report = eng.run()
    assert code == 0
    for task in report["tasks"]:
        assert task["status"] == "completed" and task["via"] == "claude"
    # the task that actually failed on codex got a FRESH -fb branch
    c1 = next(t for t in report["tasks"] if t["id"] == "c1")
    assert c1["branch"].endswith("-fb")
    assert len(c1["attempts"]) == 2
    # queued task never ran on codex, keeps a plain branch
    c2 = next(t for t in report["tasks"] if t["id"] == "c2")
    assert not c2["branch"].endswith("-fb")


def test_fallback_single_hop_when_both_limited(repo):
    workers = {
        "codex": FakeWorker("codex", default=fail(stderr="usage limit", duration=3)),
        "claude": FakeWorker("claude", default=fail(stderr="429", duration=3)),
    }
    eng = build(repo, make_tasks(("c1", "codex")), workers, fallback=True)
    code, report = eng.run()
    task = report["tasks"][0]
    assert code == 3
    assert task["status"] == "provider_limited"
    assert len(task["attempts"]) == 2  # codex, then claude — never a third hop


def test_no_fallback_without_flag(repo):
    workers = {
        "codex": FakeWorker("codex", default=fail(stderr="usage limit", duration=3)),
        "claude": FakeWorker("claude", default=ok_edit("x.txt")),
    }
    eng = build(repo, make_tasks(("c1", "codex")), workers, fallback=False)
    code, report = eng.run()
    assert report["tasks"][0]["status"] == "provider_limited"
    assert workers["claude"].calls == []


# -- concurrency caps ----------------------------------------------------

def test_max_total_bounds_the_sum(repo):
    workers = {
        "codex": FakeWorker("codex", default=ok_edit("c.txt"), delay=0.15),
        "claude": FakeWorker("claude", default=ok_edit("a.txt"), delay=0.15),
    }
    data = make_tasks(*[(f"c{i}", "codex") for i in range(3)],
                      *[(f"a{i}", "claude") for i in range(3)])
    eng = build(repo, data, workers, max_parallel=3, max_total=2)
    code, _ = eng.run()
    assert code == 0
    assert workers["codex"].max_active + workers["claude"].max_active <= 4
    total_peak = max(workers["codex"].max_active, workers["claude"].max_active)
    assert total_peak <= 2


def test_per_provider_cap(repo):
    workers = {"codex": FakeWorker("codex", default=ok_edit("c.txt"), delay=0.15)}
    data = make_tasks(*[(f"c{i}", "codex") for i in range(4)])
    eng = build(repo, data, workers, max_parallel=1, max_total=4)
    code, _ = eng.run()
    assert code == 0 and workers["codex"].max_active == 1


# -- manifest truthfulness ----------------------------------------------

def test_manifest_records_running_state_mid_flight(repo):
    """The on-disk manifest must already show a task as running while its
    worker executes (crash truthfulness, eng review 5A/D12)."""
    observed = {}

    def spy(worktree):
        m = Manifest.load(observed["run_id"])
        observed["mid_flight_status"] = m.tasks["t1"]["status"]
        return ok_edit("x.txt")(worktree)

    workers = {"codex": FakeWorker("codex", default=spy)}
    eng = build(repo, make_tasks(("t1", "codex")), workers)
    observed["run_id"] = eng.run_id
    code, _ = eng.run()
    assert code == 0 and observed["mid_flight_status"] == "running"


def test_second_run_blocked_by_lock(repo):
    """While one engine holds the repo lock, a second run must refuse."""
    from swarmlib.manifest import RepoLock, RepoLockError
    lock = RepoLock(repo)
    lock.acquire()
    try:
        eng = build(repo, make_tasks(("t1", "codex")),
                    {"codex": FakeWorker("codex")})
        with pytest.raises(RepoLockError):
            eng.run()
    finally:
        lock.release()


# -- status / clean ------------------------------------------------------

def run_small_swarm(repo):
    workers = {"codex": FakeWorker("codex", behaviors={
        "task-t1": ok_edit("out-t1.txt"), "task-t2": ok_edit("out-t2.txt")})}
    eng = build(repo, make_tasks(("t1", "codex"), ("t2", "codex")), workers)
    code, report = eng.run()
    assert code == 0
    return eng.run_id, report


def test_status_reconciles_git(repo):
    run_id, report = run_small_swarm(repo)
    view = engine_mod.status(run_id)
    for task in view["tasks"]:
        assert task["git"]["branch_exists"]
        assert task["git"]["worktree_exists"]
        assert not task["git"]["worktree_dirty"]
        assert task["git"]["ahead"] == 1
    # delete a branch behind the manifest's back — status must notice
    gitops.worktree_remove(repo, view["tasks"][0]["worktree"])
    gitops.branch_delete(repo, view["tasks"][0]["branch"])
    view = engine_mod.status(run_id)
    assert not view["tasks"][0]["git"]["branch_exists"]


def test_clean_refuses_unfolded_then_allows_after_fold(repo):
    run_id, report = run_small_swarm(repo)
    cleaned, refused = engine_mod.clean(run_id)
    assert cleaned == [] and len(refused) == 2  # nothing folded yet

    for task in report["tasks"]:  # fold both
        git(["merge", "--squash", task["branch"]], repo)
        git(["commit", "-q", "-m", f"fold {task['id']}"], repo)
    cleaned, refused = engine_mod.clean(run_id)
    assert refused == [] and set(cleaned) == {"t1", "t2"}
    for task in report["tasks"]:
        assert not gitops.branch_exists(repo, task["branch"])
        assert not Path(task["worktree"]).exists()
    assert Manifest.load(run_id).data["status"] == "cleaned"


def test_clean_force_discards_everything(repo):
    run_id, _ = run_small_swarm(repo)
    cleaned, refused = engine_mod.clean(run_id, force=True)
    assert refused == [] and set(cleaned) == {"t1", "t2"}


def test_clean_refuses_dirty_worktree(repo):
    workers = {"codex": FakeWorker("codex", default=ok_edit("p.txt", status="blocked"))}
    eng = build(repo, make_tasks(("t1", "codex")), workers)
    eng.run()
    cleaned, refused = engine_mod.clean(eng.run_id)
    assert cleaned == [] and "uncommitted changes" in refused[0]
    cleaned, refused = engine_mod.clean(eng.run_id, force=True)
    assert cleaned == ["t1"]


# -- exit codes ----------------------------------------------------------

def test_exit_code_partial_and_none(repo):
    workers = {"codex": FakeWorker("codex", behaviors={
        "task-t1": ok_edit("a.txt"), "task-t2": fail(duration=120)})}
    eng = build(repo, make_tasks(("t1", "codex"), ("t2", "codex")), workers,
                max_parallel=1)
    code, _ = eng.run()
    assert code == 2

    workers = {"codex": FakeWorker("codex", default=fail(duration=120))}
    eng = build(repo, make_tasks(("t1", "codex")), workers)
    code, _ = eng.run()
    assert code == 3
