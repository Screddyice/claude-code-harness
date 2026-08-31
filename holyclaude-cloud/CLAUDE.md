# holyclaude-cloud (vendored copy)

## What this is

A vendored copy of the `holyclaude-cloud` project, carried inside the
claude-code-harness repo so the harness ships with the `legion` orchestration
layer. `legion` decomposes a goal into tasks, dispatches local and cloud workers,
reconciles their output, and ships it; Modal provides the remote compute.

## This is not the canonical copy

The upstream project lives at `~/projects/holyclaude-cloud`
(`Screddyice/holyclaude-cloud`). **Make changes there and re-vendor them here.**
Editing this copy directly forks the two, and the divergence is invisible until
someone hits a bug that is already fixed upstream.

## Stack

Python `>=3.11`, pytest configured in `pyproject.toml`, console script `legion`.
There is no `uv.lock`, so use a venv and pip. No Node toolchain — earlier versions of
this file listed `npm run build` and `npm test`, neither of which exists.

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -e .
python3 -m pytest tests/
legion --help
```

`legion.toml` caps concurrent cloud workers. The Pro session is shared across
workers and throttles hard above roughly five, so raise `max_workers` only after
watching a run.

## Rules that apply here

Harness-wide rules are in `../CLAUDE.md` and `../AGENTS.md`. Machine hard rules:
`~/.claude/CLAUDE.md`.

Durable facts go to **Cognee**, the only memory on this machine. The
`.claude-harness/memory/` tree is scaffolding, not a live memory layer.

Every branch gets a PR, and every PR updates the repo README.
