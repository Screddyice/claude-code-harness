"""End-to-end with stub CLIs: real engine, real git, fake codex/claude binaries.

The stubs edit a file in their worktree and emit a handoff exactly the way the
real CLIs deliver one (codex: --output-last-message file; claude: JSON envelope
on stdout). This exercises worktree creation, real worker adapters, engine
commits, status reconciliation, the fold flow, and clean — everything except
the vendors' actual behavior, which smoke_live.sh covers manually.
"""
import json
import os
import stat
from pathlib import Path

import pytest

from conftest import git, make_tasks

from swarmlib import engine as engine_mod
from swarmlib import gitops
from swarmlib.engine import SwarmEngine, load_tasks

CODEX_STUB = """#!/bin/bash
# minimal codex stand-in: honors --cd and --output-last-message
cd_dir=""; out=""
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = "--cd" ] && cd_dir="${args[$((i+1))]}"
  [ "${args[$i]}" = "--output-last-message" ] && out="${args[$((i+1))]}"
done
echo "stub codex output" > "$cd_dir/codex_did.txt"
cat > "$out" <<'EOF'
{"status": "completed", "summary": "codex stub did it", "checks": ["true"], "blockers": []}
EOF
"""

CLAUDE_STUB = """#!/bin/bash
# minimal claude -p stand-in: edits cwd, prints a result envelope
echo "stub claude output" > claude_did.txt
python3 - <<'EOF'
import json
handoff = {"status": "completed", "summary": "claude stub did it",
           "checks": ["true"], "blockers": []}
print(json.dumps({"type": "result", "is_error": False,
                  "result": "```json\\n" + json.dumps(handoff) + "\\n```"}))
EOF
"""


@pytest.fixture
def stub_path(tmp_path, monkeypatch):
    bin_dir = tmp_path / "stub-bin"
    bin_dir.mkdir()
    for name, body in (("codex", CODEX_STUB), ("claude", CLAUDE_STUB)):
        script = bin_dir / name
        script.write_text(body)
        script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", f"{bin_dir}:{os.environ['PATH']}")
    return bin_dir


def test_full_lifecycle_run_status_fold_clean(repo, stub_path):
    tasks = load_tasks(make_tasks(("cx", "codex"), ("cl", "claude")), "codex")
    eng = SwarmEngine(repo, tasks, echo=lambda *_: None)  # REAL workers, stub CLIs
    code, report = eng.run()
    assert code == 0, report

    by_id = {t["id"]: t for t in report["tasks"]}
    assert by_id["cx"]["changed_files"] == ["codex_did.txt"]
    assert by_id["cl"]["changed_files"] == ["claude_did.txt"]
    assert by_id["cx"]["summary"] == "codex stub did it"
    assert by_id["cl"]["summary"] == "claude stub did it"

    view = engine_mod.status(eng.run_id)
    assert all(t["git"]["branch_exists"] and t["git"]["ahead"] == 1
               for t in view["tasks"])

    # fold ONE branch, leave the other — clean must split precisely
    git(["merge", "--squash", by_id["cx"]["branch"]], repo)
    git(["commit", "-q", "-m", "fold cx"], repo)
    cleaned, refused = engine_mod.clean(eng.run_id)
    assert cleaned == ["cx"] and len(refused) == 1 and "cl" in refused[0]
    assert (repo / "codex_did.txt").exists()

    git(["merge", "--squash", by_id["cl"]["branch"]], repo)
    git(["commit", "-q", "-m", "fold cl"], repo)
    cleaned, refused = engine_mod.clean(eng.run_id)
    assert cleaned == ["cl"] and refused == []
    for task in report["tasks"]:
        assert not gitops.branch_exists(repo, task["branch"])
        assert not Path(task["worktree"]).exists()


def test_e2e_limit_stub_trips_breaker(repo, stub_path):
    limited = stub_path / "codex"
    limited.write_text("#!/bin/bash\necho 'You have hit your usage limit' >&2\nexit 1\n")
    tasks = load_tasks(make_tasks(("c1", "codex"), ("c2", "codex")), "codex")
    eng = SwarmEngine(repo, tasks, max_parallel=1, echo=lambda *_: None)
    code, report = eng.run()
    assert code == 3
    assert all(t["status"] == "provider_limited" for t in report["tasks"])
