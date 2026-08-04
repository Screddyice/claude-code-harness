import json
import subprocess

import pytest

from swarmlib.workers import (
    ClaudeWorker, CodexWorker, WorkerResult, limit_signature, parse_handoff,
    scrubbed_env,
)

GOOD = {"status": "completed", "summary": "done", "checks": ["pytest"], "blockers": []}


# -- handoff parsing -----------------------------------------------------

def test_parse_plain_json():
    assert parse_handoff(json.dumps(GOOD))["status"] == "completed"


def test_parse_fenced_json_with_prose():
    text = "I did the thing.\n```json\n" + json.dumps(GOOD) + "\n```\n"
    assert parse_handoff(text)["summary"] == "done"


def test_parse_takes_last_fenced_block():
    first = dict(GOOD, summary="first")
    text = ("```json\n" + json.dumps(first) + "\n```\nmore words\n```json\n"
            + json.dumps(GOOD) + "\n```")
    assert parse_handoff(text)["summary"] == "done"


def test_parse_garbage_and_empty():
    assert parse_handoff("no json here at all") is None
    assert parse_handoff("") is None
    assert parse_handoff(None) is None


def test_parse_rejects_wrong_status():
    bad = dict(GOOD, status="maybe")
    assert parse_handoff(json.dumps(bad)) is None


def test_parse_normalizes_missing_lists():
    minimal = {"status": "blocked", "summary": "stuck"}
    parsed = parse_handoff(json.dumps(minimal))
    assert parsed == {"status": "blocked", "summary": "stuck", "checks": [], "blockers": []}


# -- limit signatures ----------------------------------------------------

@pytest.mark.parametrize("text", [
    "HTTP 429 too many requests", "You have hit your usage limit",
    "rate-limited, retry later", "quota exceeded for this billing period",
])
def test_limit_signature_hits(text):
    assert limit_signature(text)


def test_limit_signature_misses():
    assert not limit_signature("SyntaxError: unexpected token")
    assert not limit_signature("")


def test_worker_result_fast_and_limit():
    fast = WorkerResult(1, "", "usage limit reached", 3.0)
    assert fast.fast_failure and fast.limit_hit
    slow = WorkerResult(1, "", "some crash", 120.0)
    assert not slow.fast_failure and not slow.limit_hit
    ok = WorkerResult(0, "", "usage limit mentioned in passing", 3.0)
    assert not ok.limit_hit  # success never counts as a limit


# -- env scrubbing -------------------------------------------------------

def test_scrubbed_env_allowlist(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_BASE_URL", "http://localhost:8083")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-secret")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-secret")
    monkeypatch.setenv("PATH", "/usr/bin")
    env = scrubbed_env()
    assert "ANTHROPIC_BASE_URL" not in env
    assert "ANTHROPIC_API_KEY" not in env
    assert "OPENROUTER_API_KEY" not in env
    assert env["PATH"] == "/usr/bin"
    assert "HOME" in env


# -- claude worker -------------------------------------------------------

def claude_envelope(result_text, is_error=False):
    return json.dumps({"type": "result", "is_error": is_error, "result": result_text})


def test_claude_cmd_construction_and_env(tmp_path, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-secret")
    seen = {}

    def runner(cmd, **kwargs):
        seen["cmd"], seen["kwargs"] = cmd, kwargs
        return subprocess.CompletedProcess(
            cmd, 0, claude_envelope("```json\n" + json.dumps(GOOD) + "\n```"), "")

    worker = ClaudeWorker(runner=runner)
    result = worker.run_task("do the thing", tmp_path)
    cmd = seen["cmd"]
    assert cmd[0] == "claude" and cmd[1] == "-p"
    assert "--output-format" in cmd and "json" in cmd
    assert "--permission-mode" in cmd and "acceptEdits" in cmd
    assert "--allowedTools" in cmd and "Bash" in cmd
    assert "--strict-mcp-config" in cmd
    assert cmd[cmd.index("--setting-sources") + 1] == "project"
    assert seen["kwargs"]["cwd"] == str(tmp_path)
    assert "ANTHROPIC_API_KEY" not in seen["kwargs"]["env"]
    assert result.ok and result.handoff["status"] == "completed"


def test_claude_prompt_forbids_git_and_nested_models(tmp_path):
    seen = {}

    def runner(cmd, **kwargs):
        seen["prompt"] = cmd[2]
        return subprocess.CompletedProcess(cmd, 0, claude_envelope("x"), "")

    ClaudeWorker(runner=runner).run_task("my task text", tmp_path)
    prompt = seen["prompt"]
    assert "Do NOT run any git write command" in prompt
    assert "llmjury" in prompt and "subagents" in prompt
    assert "my task text" in prompt


def test_claude_is_error_envelope_fails(tmp_path):
    def runner(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, claude_envelope("bad", is_error=True), "")

    result = ClaudeWorker(runner=runner).run_task("t", tmp_path)
    assert not result.ok and result.handoff is None


def test_claude_unparseable_envelope_falls_back(tmp_path):
    def runner(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, json.dumps(GOOD), "")

    result = ClaudeWorker(runner=runner).run_task("t", tmp_path)
    assert result.ok and result.handoff["status"] == "completed"


def test_claude_timeout_and_oserror(tmp_path):
    def timeout_runner(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd, 5)

    result = ClaudeWorker(runner=timeout_runner).run_task("t", tmp_path)
    assert result.returncode == 124 and "timed out" in result.stderr

    def os_error_runner(cmd, **kwargs):
        raise OSError("exec format error")

    result = ClaudeWorker(runner=os_error_runner).run_task("t", tmp_path)
    assert result.returncode == 127


# -- codex worker --------------------------------------------------------

def test_codex_cmd_and_output_file(tmp_path):
    seen = {}

    def runner(cmd, **kwargs):
        seen["cmd"] = cmd
        out = cmd[cmd.index("--output-last-message") + 1]
        with open(out, "w") as fh:
            json.dump(GOOD, fh)
        return subprocess.CompletedProcess(cmd, 0, "", "")

    worker = CodexWorker(runner=runner)
    result = worker.run_task("do it", tmp_path, model="gpt-5.4", effort="low")
    cmd = seen["cmd"]
    assert cmd[:3] == ["codex", "exec", "--ephemeral"]
    assert "--sandbox" in cmd and "workspace-write" in cmd
    assert "--cd" in cmd and str(tmp_path) in cmd
    assert "--model" in cmd and "gpt-5.4" in cmd
    assert result.ok and result.handoff["status"] == "completed"


def test_codex_missing_output_file_falls_back_to_stdout(tmp_path):
    def runner(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, json.dumps(GOOD), "")

    result = CodexWorker(runner=runner).run_task("t", tmp_path)
    assert result.handoff["status"] == "completed"


def test_codex_nonzero_exit_no_handoff(tmp_path):
    def runner(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 2, "", "some failure")

    result = CodexWorker(runner=runner).run_task("t", tmp_path)
    assert not result.ok and result.handoff is None


def test_missing_executable_raises():
    with pytest.raises(RuntimeError, match="not found"):
        ClaudeWorker(executable="definitely-not-a-real-cli-xyz")
