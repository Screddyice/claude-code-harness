---
name: swarm
description: "Fan 2+ independent bounded coding tasks out to parallel headless Codex workers (billed to the OpenAI subscription) from a Claude Code session. Each worker edits in an isolated git worktree; the engine commits; you review and fold. Use when tasks are independent, well-specified, and worth running while you keep working."
---

# swarm — parallel Codex workers from a Claude Code session

Dispatch bounded tasks to headless `codex exec` workers running on the OTHER
subscription, so extra cloud agents work while this session continues. One
engine command; workers never touch git or the network side effects — the
engine commits, you review and fold.

## When to use

- 2 or more INDEPENDENT, well-specified tasks (mechanical changes, isolated
  features, per-module chores) that don't need this session's context.
- You want progress on them in parallel without spending this session's
  Claude quota on them.

Do NOT use for: tasks needing session context or judgment calls, sequenced
work, RS21 repos (the engine refuses), or a single quick task (`llmjury
delegate` or just doing it is cheaper).

## Workflow

1. Commit your work first — the engine refuses a dirty tree by default
   (workers branch from HEAD and never see uncommitted changes).
2. Write `tasks.json` — each task: unique `id`, self-contained `task` brief
   (scope, acceptance, which checks to run), optional `files` (advisory scope
   hint; the engine warns when two tasks overlap):

```json
{"tasks": [
  {"id": "fix-timeouts", "via": "codex", "files": ["src/net/client.py"],
   "task": "In src/net/client.py, add a 30s timeout to every requests call. Run pytest tests/net/ and report results."},
  {"id": "readme-badges", "via": "codex", "files": ["README.md"],
   "task": "Add CI and license badges to README.md header. No other edits."}
]}
```

3. Run (backgrounding is fine — it's a plain process):

```bash
swarm run --workspace . --tasks tasks.json --via codex --json
```

   Exit codes: 0 = every task completed, 2 = partial, 3 = none. 2 is NOT an
   error — read per-task statuses in the JSON. `provider_limited` /
   `provider_unavailable` mean that CLI's subscription hit its limit or the
   CLI keeps failing fast; those tasks were skipped, not errored. Add
   `--fallback` to re-route them to claude workers instead.

4. Review each result: `swarm status <run-id>`, then per branch
   `git diff <base>..swarm/<run-id>/<task-id>` and read the handoff summary,
   checks, and blockers in the report.
5. Fold what you accept into YOUR branch:
   `git merge --squash swarm/<run-id>/<task-id>` + commit (normal PR flow —
   never merge worker branches to main directly, never push them).
6. `swarm clean <run-id>` — it refuses to delete unfolded or uncommitted
   worker output unless you pass `--force`.

## Guardrails

- Defaults: 3 workers per provider, 4 total (`--max-total`). Don't raise the
  total while local models (Ollama council) are resident — worker CLIs are
  ~0.5GB each and this machine has panicked on summed memory before.
- Workers run with acceptEdits scoped to their worktree, a scrubbed env (no
  API keys beyond their own OAuth), and prompts forbidding git/push/PR,
  nested llmjury/local models, and subagents.
- A `blocked` task leaves its worktree uncommitted for inspection — look at
  it before cleaning.
