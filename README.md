> **claude-mem removed 2026-08-02.** Do not reinstall the thedotmack plugin, host proxy, mcp-search, or Grok mem hooks. Shared observation memory is gone from this harness.

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
│   ├── hooks.json.example            # optional Codex hook wiring
│   └── grok/                         # Grok-native hooks (PR tracking, HyperSwarm)
├── scripts/
│   ├── init-codex-harness.sh         # idempotently creates .codex-harness/
│   ├── audit-codex-migration.sh       # reports remaining Claude-only surfaces
│   ├── install-llmjury-orchestration.sh # optional Claude/Codex delegation setup
│   ├── install-grok-harness.sh       # install Grok native wiring
│   ├── grok/                         # Grok bridge scripts (HyperSwarm)
│   ├── hooks/                           # shared hook logic and runtime adapters
│   ├── swarm/                        # cross-CLI parallel agent dispatch engine
│   ├── test-swarm.sh                 # swarm pytest suite runner
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

## Swarm — Cross-CLI Parallel Agent Dispatch

`scripts/swarm/` fans independent, bounded task briefs out to headless worker
agents on the OTHER subscription's CLI — `codex exec` workers from a Claude Code
session, `claude -p` workers from a Codex session — so both accounts' cloud
agents run at once. Each task gets an isolated git worktree on a scratch branch
(`swarm/<run-id>/<task-id>`); workers EDIT ONLY, the engine runs every git
command and creates one commit per task, and the orchestrating session reviews
each diff and folds accepted branches back with `git merge --squash`.

```text
tasks.json ─► swarm run ─► worktree per task ─► codex/claude workers (≤4 total)
                                │                        │ edits only
                                └── engine commits ◄─────┘
      review diffs ─► git merge --squash ─► swarm clean <run-id>
```

Install the `swarm` CLI shim plus the Claude and Codex skills:

```bash
scripts/swarm/install.sh
```

Contract highlights:

- `swarm run --workspace . --tasks tasks.json [--via codex|claude] [--fallback]`
  — exit 0 all tasks completed, 2 partial, 3 none. Partial is not an error.
- A provider hitting its usage limit trips a per-provider circuit breaker
  (message signatures plus a 2-consecutive-fast-failure backstop): its queued
  tasks are skipped as `provider_limited`, never fatal to the run, and
  `--fallback` re-routes them to the other provider in fresh worktrees.
- Refuses dirty trees by default (workers branch from HEAD and cannot see
  uncommitted work; `--allow-dirty` overrides), refuses rs21 repositories, and
  one PID-locked run per repo at a time.
- Concurrency: 3 workers per provider, 4 total by default (`--max-total`) —
  bound the process SUM before raising it while local models are resident.
- `swarm status <run-id>` reconciles the manifest against git reality;
  `swarm clean <run-id>` refuses to delete unfolded or uncommitted worker
  output unless `--force`.
- Workers never commit, push, or open PRs; they run with scrubbed environments
  (no inherited API keys) and prompts that forbid nested local-model runs and
  subagents.

Tests: `scripts/test-swarm.sh` (pytest, includes a stub-CLI end-to-end).
Before first real use, run `scripts/swarm/smoke_live.sh` once — it verifies the
real CLIs' headless flag behavior with one trivial task per provider.

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

The `scripts/hooks/` directory is the canonical runtime for hooks shared by Claude Code,
Codex, and Grok. Point each tool's config at this directory instead of keeping executable
copies under `~/.claude`, `~/.codex`, and `~/.grok`. All three run the same automatic PR
tracker. Claude and Codex also run the local Ollama diff reviewer; Grok deliberately does
not (see [Grok harness support](#grok-harness-support)). Thin Stop-hook adapters preserve
each tool's JSON contract:

| Behavior | Claude Code | Codex | Grok |
|----------|-------------|-------|------|
| Push branches and open draft PRs | `auto-pr-push.sh` | `auto-pr-push.sh` | `auto-pr-push.sh` (via `examples/grok/pr-tracking.json`) |
| Enforce one PR per work branch | `enforce-pr-claude.sh` | `enforce-pr-codex.sh` | `enforce-pr-grok.sh` |
| Review the current diff with Ollama | `local-diff-review.sh` | `local-diff-review-codex.sh` | **off** (GPU panic risk) |
| Distil session left-off into HyperSwarm | Claude settings | `codex-hyperswarm-leftoff.sh` | `scripts/grok/hyperswarm-leftoff.sh` |
| Sample OAuth login expiry | `oauth-expiry-monitor.sh` | n/a | n/a |

`codex-hyperswarm-leftoff.sh` runs on Codex `SessionEnd` and gives Codex parity
with Claude Code's HyperSwarm feed: it hands the ending session's id to
`hyperswarm capture --runtime mem0_session` (significance-gated, with the
left-off fallback) and pushes the store to the canonical host, so remote
Hermes/Telegram agents can see where Codex coding left off. The hook returns
immediately and a detached worker sleeps 5s so Mem0 lands the session's
memories before the distiller reads them. `Mem0SessionSource` matches on
`metadata.session_id` and writes nothing when Mem0 holds no memories for the
session, so no local gate decides whether capture is worth running. Recursion
stops at the inherited `CODEX_NO_INTERACTIVE` marker set by the gate's
own `codex exec` child, plus a skip for sessions whose prompt is the gate
preamble. Logs to `/tmp/hs-codex-push.log`.

The shared PR hook writes its log to `~/.cache/claude-code-harness/auto-pr-push.log`.
Set `HARNESS_PR_OWNERS` to a space-separated allowlist in both tool configs; an empty
allowlist disables automatic pushes.

#### Login-expiry monitor

`oauth-expiry-monitor.sh` runs on Claude Code `SessionStart` (loud) and `SessionEnd`
(`--quiet`). It stays silent while your login is healthy. Codex and Grok authenticate
through their own CLIs, so this hook is Claude-only.

It exists because Claude Code's banner is easy to misread. The banner reads one field,
`refreshTokenExpiresAt` in the macOS keychain item `Claude Code-credentials`, and renders
`Math.ceil(remaining / 86400000)`. Anything from one second to 24 hours prints as
**"1 day"**. There is no "0 days" and no hours display. Only `/login` mints a new refresh
token; the 8-hour access token rotating each session does not extend that window. So a
refresh token parked near its expiry prints "Your login expires in 1 day" every day while
auth keeps working, which reads as a stuck warning rather than a real deadline. Claude
Code also computes the banner once per session at mount and memoizes it, so a session you
left running for 15 hours still shows what was true at launch even after you re-auth.
Restart the session to clear a stale banner.

The hook appends one JSON sample per run to `~/.claude/oauth-expiry.log` and speaks up on
two conditions:

| Condition | What it means |
|---|---|
| Expiry moved **backwards** since the last sample | A stale credential blob overwrote a fresh one. This is what makes the warning recur. |
| Refresh token inside the 3-day window | Run `/login` once, deliberately, instead of ignoring a daily banner. |

`oauth-expiry-check.sh` prints the same numbers on demand, with `--log` to append a
sample. Both read the keychain and never write it. Sampling is event-driven with no
polling timer, per the workspace no-wake-to-check rule.

Overrides: `LOG_PATH`, `NOTIFY_STAMP`, `MONITOR_NO_NOTIFY=1` to suppress the macOS
notification (tests, headless and cron runs), and `OAUTH_MONITOR_TEST_JSON` to feed a
synthetic credential instead of reading the keychain. Run
`scripts/test-oauth-expiry-monitor.sh` after changing either script; it covers the healthy
path, a forward roll, the regression and expiring alerts, `--quiet`, a malformed
credential blob, and the shape of the emitted hook JSON.

#### Duplicate-PR guard after a squash merge

The hook decided whether a branch still needed a PR by asking `gh pr list --state open`.
After a **squash** merge the branch's PR is `MERGED`, not open, so that count came back 0
and the hook opened a *second* PR for work already sitting on the base — while its push
re-created the remote branch the merge had just deleted. The "commits ahead of base"
precondition cannot catch this either: a squash merge rewrites the commits, so the
branch's own commits are never ancestors of the base and the branch looks permanently
ahead.

Seen live on 2026-07-31: `Screddyice/llm-jury#18` was opened ten seconds after `#17`
squash-merged, carrying the same three commits and an empty diff against `main`. Left
alone this recurs on every squash merge where the session has not yet switched branches.

Two guards now run before the push:

| Guard | Cost | Catches |
|---|---|---|
| base already contains this tree (`git diff --quiet <base> HEAD`) | local, free | the branch adds nothing, once the local base ref has caught up |
| this exact commit is already merged (`gh pr list --state merged` head SHA) | one API call | the race above, where the local base ref is still pre-merge |

The second is the load-bearing one, and it is keyed on the **merged head SHA** rather
than the branch name, so reusing a branch for new commits after its PR merged still
opens a fresh PR. This brings the automatic hook in line with `track-branch-pr.sh`,
which already refused to add a second review history to a closed or merged PR.

Because Claude Code, Codex, and Grok all run this same script — Claude via settings,
Codex via `~/.codex/hooks.json`, Grok via native `~/.grok/hooks/pr-tracking.json` — the
guard applies to all three. Do **not** enable Grok `[compat.claude] hooks = true` to get
this behavior; that imports Claude's full hook chain (including the Ollama reviewer) and
has panicked this host. Run `scripts/test-auto-pr-push-merged-guard.sh` after changing it.
The old top-level `scripts/codex-local-diff-review.sh` remains as a compatibility entry
point. Run `scripts/test-shared-hooks.sh` after changing shared logic or an adapter.

## Workspace root (multi-org)

When this harness is installed on a multi-org machine (e.g. Shawn's `~/projects`), hooks and
skills are **user-global**. Opening Claude Code / Codex / Grok from the workspace root or
from any org/repo under it uses the same harness. Workspace docs: `~/projects/CLAUDE.md`,
`~/projects/AGENTS.md`. Org folders only add thin pointers; git `origin` selects company
credentials.

| Harness | Workspace entry points |
|---------|------------------------|
| Claude Code | `~/projects/CLAUDE.md`, `~/projects/.claude/skills` → `~/.claude/skills` |
| Codex | `~/.codex/AGENTS.md` + `~/projects/AGENTS.md`; skills under `~/.codex/skills` (agents skills linked); hooks in `~/.codex/hooks.json`; zsh `codex` loads `~/projects/.env` |
| Grok | `~/.grok/rules/projects-workspace.md`; `[skills].paths` includes agents + claude skills; native hooks; `grok` wrapper loads `~/projects/.env` |

## Grok harness support

Grok Build TUI (`~/.grok`) gets a **native** harness slice, not Claude-compat import.

### Architecture (what works, and what must stay off)

| Channel | How it reaches Grok | Notes |
|---------|---------------------|-------|
| HyperSwarm left-off | `~/.grok/hooks/hyperswarm.json` → `hyperswarm-leftoff.sh` | Same distiller path as Codex; detached worker sleeps 5s before capturing |
| PR tracking | `~/.grok/hooks/pr-tracking.json` → shared `auto-pr-push.sh` + `enforce-pr-grok.sh` | Owned-org allowlist only |
| Local Ollama diff review | **not wired** | Resident ~7.5 GB + council load kernel-panicked the Mac twice on 2026-07-31 |
| `[compat.claude] hooks/mcps` | **must stay false** | True double-fires Claude's chain into Grok; was a root cause of the panics |

### Install

```bash
# From this repo — idempotent. Syncs scripts + hook JSON into ~/.grok.
scripts/install-grok-harness.sh
scripts/install-grok-harness.sh --check   # status only

# First-time config.toml notes (installer never overwrites your file):
#   [compat.claude]
#   skills = true
#   rules = true
#   agents = true
#   hooks = false         # use native ~/.grok/hooks/*.json instead
```

Restart Grok (new session) after install so hooks reload. Confirm with `/hooks` and:

```bash
  "SELECT platform_source, COUNT(*) FROM sdk_sessions GROUP BY 1;"
```

A healthy setup shows `platform_source=grok` rows growing as you work, context in
reporting `proxy=host`, and **no** Ollama model loaded solely for Grok mem or a Grok Stop
(`ollama ps` should stay empty unless you are in a local/qwen coding session or fusion).

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
