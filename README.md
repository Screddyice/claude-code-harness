# codex-harness

A starter template for organizing a multi-company [OpenAI Codex CLI](https://github.com/openai/codex)
workspace.

This is **not** a fork of Codex itself. It is the thin local layer around Codex:
sanitized `AGENTS.md` templates, a conservative `~/.codex/config.toml` example,
per-repo `.codex-harness/` scaffolding, and a local Codex plugin marketplace stub.

The repo was adapted from a Claude Code harness. The Claude-specific surfaces
(`~/.claude/settings.json`, hooks, status lines, and `CLAUDE.md`) are mapped to
Codex-native concepts. A staged migration can keep `CLAUDE.md` as a configured
fallback until each repo has an adapted `AGENTS.md`.

## What's Inside

```
codex-harness/
├── examples/
│   ├── AGENTS.md.workspace.example   # ~/projects/AGENTS.md template
│   ├── AGENTS.md.project.example     # per-repo AGENTS.md starter
│   ├── config.toml.example           # ~/.codex/config.toml starter
│   └── hooks.json.example            # optional Codex hook wiring
├── scripts/
│   ├── init-codex-harness.sh         # idempotently creates .codex-harness/
│   ├── audit-codex-migration.sh       # reports remaining Claude-only surfaces
│   ├── install-llmjury-orchestration.sh # optional Claude/Codex delegation setup
│   ├── hooks/                           # shared hook logic and runtime adapters
│   ├── track-branch-pr.sh             # pushes a branch and opens/updates its draft PR
│   └── codex-workspace-summary.sh    # quick local sanity summary
└── marketplace/
    └── example-local/                # Codex local plugin marketplace example
```

## Who This Is For

You operate multiple companies or orgs out of a single workspace directory, each with
its own:

- Git history
- MCP and app connector accounts
- Cloud infrastructure
- Webhook receivers and event handlers
- Project tracker
- Project-level agent instructions

The goal is to keep each company's automations, credentials, and agent context isolated
while sharing one Codex setup.

## Codex Mapping

| Claude harness concept | Codex equivalent in this repo |
|------------------------|-------------------------------|
| `CLAUDE.md` | `AGENTS.md` |
| `~/.claude/settings.json` | `~/.codex/config.toml` plus CLI commands |
| SessionStart hook | Codex `SessionStart` hook in `hooks.json`, explicit initializer, or a shell wrapper |
| Claude status line | No direct Codex equivalent; use `scripts/codex-workspace-summary.sh` |
| Claude plugin marketplace | `.agents/plugins/marketplace.json` and `codex plugin marketplace add` |
| Claude MCP JSON | `codex mcp add ...` entries stored by Codex |

## Installation

```bash
# 1. Clone this repo
git clone https://github.com/Screddyice/claude-code-harness.git codex-harness
cd codex-harness

# 2. Back up your Codex config, then install the example
cp ~/.codex/config.toml ~/.codex/config.toml.backup 2>/dev/null || true
cp examples/config.toml.example ~/.codex/config.toml

# 3. Install the workspace AGENTS.md template
cp examples/AGENTS.md.workspace.example ~/projects/AGENTS.md
# Edit ~/projects/AGENTS.md for your orgs, credentials policy, and infrastructure.

# 4. Initialize a repo-level harness where you want local memory/state scaffolding
scripts/init-codex-harness.sh ~/projects/my-org/my-repo

# 5. Optional: wire Codex hooks after editing paths in examples/hooks.json.example
cp examples/hooks.json.example ~/.codex/hooks.json

# 6. Add a local Codex plugin marketplace, if you use in-house plugins
codex plugin marketplace add "$(pwd)/marketplace/example-local"

# 7. Optional: install bidirectional Claude/Codex orchestration (requires LLM-Jury)
scripts/install-llmjury-orchestration.sh

# 8. Audit the whole workspace; this command is read-only.
scripts/audit-codex-migration.sh ~/projects
```

## Optional LLM-Jury Orchestration

When `llmjury` is installed, the harness can make Claude Code and Codex cooperate from
either starting point:

```text
Claude session → Claude plans → Codex executes ─┐
                                                ├→ verify → finish
Codex session  → Claude plans ← Codex requests ─┘    │
                         ↑                           │ new evidence
                         └──── dynamic replan ───────┘

Testable Python unit → local Ollama council → independent verifier → integrate
```

Run the idempotent installer:

```bash
scripts/install-llmjury-orchestration.sh
```

It calls `llmjury install-claude` and `llmjury install-codex`, then verifies both
skill files. On non-trivial work, the Codex skill requests a read-only structured
Claude plan before execution and asks Claude to replan when tests or repository
evidence invalidate the plan. The Claude skill delegates bounded implementation to a
workspace-confined Codex agent. Local models remain limited to code units with a real
oracle; the verifier, not a vote, determines whether their output can be integrated.

This integration is optional: the harness works without LLM-Jury. Restart both Claude
Code and Codex after first installation so their skill catalogs refresh. Use `--force`
only to replace locally modified installed copies.

## Continuous PR Tracking

Do not wait for a complete feature before creating its review surface. After the first
commit on a work branch, run:

```bash
scripts/track-branch-pr.sh /path/to/repo
```

The command refuses `main` and `master`, verifies GitHub CLI authentication, pushes the
current branch, and opens a draft PR when none exists. On later commits it pushes the
same branch and reports the existing PR. A closed or merged PR causes a failure so one
branch cannot silently accumulate a second review history. Set `PR_TRACK_BASE` or
`PR_TRACK_REMOTE` only when a repository does not use its detected defaults.

The workspace and project `AGENTS.md` templates make this first-commit draft-PR flow the
default agent policy. PR creation is intentionally explicit rather than a hidden Git
hook: commits stay usable offline, while every agent session is still required to run
the tracker before switching branches or handing off work. The script never merges.

## Per-Repo Harness

`scripts/init-codex-harness.sh` creates an idempotent `.codex-harness/` directory in a
git repository:

```
.codex-harness/
├── agents/context.json
├── config.json
├── features/{active.json,archive.json}
├── impact/{change-log.json,dependency-graph.json}
├── memory/{learned,episodic,semantic,procedural}/...
├── prd/analyst-prompts.json
├── session-briefing.md
└── sessions/.current-session-id
```

If the target repo does not already have `AGENTS.md`, the script also seeds a small
project-level starter.

## Optional Hooks

Codex supports lifecycle hooks including `SessionStart`, `Stop`, tool hooks, and
compaction hooks. This harness includes `examples/hooks.json.example` for users who
want auto-init behavior similar to the old Claude SessionStart hook. Codex requires
non-managed hooks to be reviewed and trusted; inspect them with `/hooks` after install.

The `scripts/hooks/` directory is the canonical runtime for hooks shared by Claude Code
and Codex. Point each tool's config at this directory instead of keeping executable
copies under `~/.claude` and `~/.codex`. Both tools run the same automatic PR tracker
and local diff reviewer. Thin Stop-hook adapters preserve each tool's JSON contract:

| Behavior | Claude Code command | Codex command |
|----------|---------------------|---------------|
| Push branches and open draft PRs | `scripts/hooks/auto-pr-push.sh` | `scripts/hooks/auto-pr-push.sh` |
| Enforce one PR per work branch | `scripts/hooks/enforce-pr-claude.sh` | `scripts/hooks/enforce-pr-codex.sh` |
| Review the current diff with Ollama | `scripts/hooks/local-diff-review.sh` | `scripts/hooks/local-diff-review-codex.sh` |
| Distil session left-off into HyperSwarm | (wired directly in `~/.claude/settings.json`) | `scripts/hooks/codex-hyperswarm-leftoff.sh` |

`codex-hyperswarm-leftoff.sh` runs on Codex `SessionEnd` and gives Codex parity
with Claude Code's HyperSwarm feed: it hands the ending session's id to
`hyperswarm capture --runtime claude_mem_session` (significance-gated, with the
left-off fallback) and pushes the store to the canonical host, so remote
Hermes/Telegram agents can see where Codex coding left off. A detached worker
waits for claude-mem's async session summary before capturing, and two guards
stop recursion: the inherited `CODEX_NO_INTERACTIVE` marker set by the gate's
own `codex exec` child, plus a skip for sessions whose prompt is the gate
preamble. Logs to `/tmp/hs-codex-push.log`.

The shared PR hook writes its log to `~/.cache/claude-code-harness/auto-pr-push.log`.
Set `HARNESS_PR_OWNERS` to a space-separated allowlist in both tool configs; an empty
allowlist disables automatic pushes.
The old top-level `scripts/codex-local-diff-review.sh` remains as a compatibility entry
point. Run `scripts/test-shared-hooks.sh` after changing shared logic or an adapter.

### Local diff reviewer GPU cost

The reviewer runs on `Stop`, so it fires once per turn. It used to default to
`gemma3:12b` with no rate limit, which meant a 13 GB load onto the GPU dozens of
times in a working session. Two defaults changed on 2026-07-31:

| Setting | Default | Purpose |
|---------|---------|---------|
| `LOCAL_REVIEW_MODEL` | `qwen3.5:4b` | Small model instead of `gemma3:12b`'s ~13 GB |
| `LOCAL_REVIEW_KEEP_ALIVE` | `30s` | Unload after the review instead of holding GB between turns |
| `LOCAL_REVIEW_COOLDOWN_SECONDS` | `1200` | Skip if this repo was reviewed less than 20 minutes ago |
| `LOCAL_REVIEW` | `1` | Set to `0` to disable the reviewer entirely |

#### Measure resident size, not weights

This table originally claimed the small model cost "~3 GB, and loads fast enough to stay
resident between turns". Both halves of that were wrong, and expensively so.

~3 GB is the model's **weights**. Ollama sizes the KV cache as `num_ctx ×
OLLAMA_NUM_PARALLEL`, and the reviewer asks for `num_ctx 24576`, so at 4 parallel slots
the tag measured **7.5 GB resident** with `ollama ps`. Keeping that resident between
turns then denied the memory to everything else on the same Ollama server. Alongside an
llm-jury council it over-committed a 36 GB Mac and panicked it twice on 2026-07-31
(`watchdog timeout: no checkins from watchdogd`) — wired GPU allocations cannot be paged
out, so the host starves its kernel watchdog rather than raising a catchable OOM.

Two corrections followed. `keep_alive` is now short by default: with a 20 minute
cooldown the next review is far away, so lingering trades a few seconds of reload for
several GB held hostage. And the default tag dropped the `-64k` suffix — same model ID,
but the plain tag cannot silently fall back to a 64k context if `num_ctx` is ever
dropped from the request.

When changing the model or context here, measure with `ollama ps` rather than reading
`ollama list`; the first reports resident size, the second reports bytes on disk, and on
a memory-constrained host the gap between them is the whole problem.

The cooldown collapses a burst of rapid turns into one review over the
accumulated diff. It is keyed per repository and checked *before* the diff-hash
marker is written, so a skipped turn does not mark that diff as already
reviewed; an unchanged diff is still reviewed once the cooldown expires. A
missing or corrupt stamp reads as "never reviewed" and lets the review proceed,
so the reviewer cannot be wedged shut by a bad cache file.

Findings still arrive mid-session. The Claude Code hook sets `asyncRewake`, so
the review runs in the background and wakes the session when it flags
something; moving the reviewer to `SessionEnd` would leave no session to wake.

Run `scripts/test-local-diff-review-cooldown.sh` after changing the cooldown or
cache-key logic.

## Migration Audit

`scripts/audit-codex-migration.sh` checks the workspace without changing it. It reports:

- `CLAUDE.md` files without a sibling `AGENTS.md`.
- `AGENTS.md` files larger than Codex's default 32 KiB instruction budget.
- `.claude-harness/` directories without `.codex-harness/` siblings.
- Missing `CLAUDE.md` fallback or an undersized instruction budget in Codex config.

The fallback is transitional. Codex prefers `AGENTS.md` when both files exist, so repos
can be adapted one at a time without losing local instructions in the meantime.
Legacy-only instruction and harness paths are informational when the fallback is active;
pass `--strict` as the second argument to make them fail the audit. Third-party, vendored,
and embedded skill trees are excluded by default because their instruction files are owned
upstream and should not be rewritten by a workspace migration.

Use the explicit initializer when you want predictable behavior:

```bash
scripts/init-codex-harness.sh /path/to/repo
```

## MCP And Apps

Use Codex's CLI to register MCP servers instead of editing opaque config by hand:

```bash
codex mcp add mercury -- /path/to/mercury-mcp --stdio
codex mcp add docs --url https://example.com/mcp
codex mcp list
```

For app connectors and plugins, prefer Codex-native plugin/app capabilities. Keep
company-specific app accounts separated in instructions and environment naming.

## Sanitization

This repo intentionally contains **no** secrets, API keys, OAuth tokens, server IPs,
account IDs, client names, team member names, or internal project identifiers. All
company-specific content uses placeholders.

## License

[MIT](LICENSE)
