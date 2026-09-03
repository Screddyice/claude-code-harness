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
│   └── hooks.json.example            # optional Codex hook wiring
├── scripts/
│   ├── init-codex-harness.sh         # idempotently creates .codex-harness/
│   ├── audit-codex-migration.sh       # reports remaining Claude-only surfaces
│   ├── install-llmjury-orchestration.sh # optional Claude/Codex delegation setup
│   ├── install-claude-resilient-updater.sh # resumable Claude native updates on macOS
│   ├── claude-manual-update             # checksum-verified update worker
│   ├── hooks/                           # shared hook logic and runtime adapters
│   ├── test-shared-hooks.sh          # hook unit tests (PR base resolution, enforcement)
│   ├── swarm/                        # cross-CLI parallel agent dispatch engine
│   ├── test-swarm.sh                 # swarm pytest suite runner
│   ├── track-branch-pr.sh             # pushes a branch and opens/updates its draft PR
│   ├── gbrowse                       # headed-browser wrapper that survives a session
│   ├── dns-preflight.sh              # what breaks if I move this domain's DNS now
│   ├── dns-postflight.sh             # did the cutover land, and did mail survive
│   └── codex-workspace-summary.sh    # quick local sanity summary
└── marketplace/
    └── example-local/                # Codex local plugin marketplace example
```

## Where an auto-opened PR is aimed

`scripts/hooks/auto-pr-push.sh` pushes a branch and opens its draft PR the moment
it has a commit. The base it picks is derived per branch, never assumed.

Three questions, answered separately, because they have different answers:

1. **Where did this branch fork?** Scored by total divergence (`behind + ahead`)
   against `origin/HEAD`, `main`, `master`, `dev`, `develop`, `staging`. Remote
   refs are scored alone whenever any exist — a stale local `main` looks closer
   than the real one exactly when it matters.
2. **Is this branch stacked on another one?** `hook_tighten_base_to_parent`. The
   scorer above only knows trunk and the integration branches, so a branch cut from
   another *feature* branch scores `dev` or `main` — and the PR then carries the
   parent's commits as its own. Three of them on `nebos-v2` #531; ten on the branch
   behind #508, which belonged to `hotfix/nebby-slack-backoff`.

   Detected from the oldest commit the PR would carry: if another remote branch
   already contains it, that commit is not this branch's work and that branch is the
   base. One `git branch -r --contains`, not a count per remote — this runs after
   every Bash call. The base only ever moves forward, so a branch forked straight off
   `dev` is untouched.
3. **Where is a PR from this branch allowed to land?** `hook_resolve_pr_base`.

The second question exists because trunk is a deploy branch in any repo that keeps
an integration branch, and it takes work only after that branch. `nebos-v2` states
it in `guard-main-base.yml`: only `dev`, `promote/*` and `hotfix/*` may target
`main`. A branch cut from `main` — a stale checkout, a rebase onto the wrong ref —
still scores `main` as its fork point, so the hook aimed there and CI rejected it
on arrival. That happened on `nebos-v2` #531 and #532, and #365 before them.

Precedence, most specific first:

| | Source | Use it when |
|---|---|---|
| 1 | `HOOK_PR_BASE` in the environment | a one-off, or a wrapper that knows better |
| 2 | `.claude-harness/pr-base` in the repo | the repo has a policy and should say so itself |
| 3 | the integration-branch rule | everything else |

The rule: if the fork point resolved to `main`/`master`, the repo has an
`origin/dev` or `origin/develop`, and the branch is not itself `dev`/`develop` or
an escape hatch (`promote/*`, `hotfix/*`, `release/*`), aim at the integration
branch instead. A repo with no integration branch is untouched, which is most of
them.

Verify what a branch would target without opening anything:

```bash
( . scripts/hooks/hook-common.sh
  hook_load_branch_context && echo "$HOOK_BRANCH -> $HOOK_BASE_BRANCH" )
```

Covered by `scripts/test-shared-hooks.sh`: a `fix/*` branch in a repo with `dev`,
a `hotfix/*` keeping trunk, a trunk-only repo, a repo-declared base, a branch stacked
on a feature branch (base and commit count both), and a branch forked straight off
`dev` that must not move.

Checked against the real branches too, which is the check that matters — a truncated
function once passed `bash -n` and the whole suite while being broken:

```
feat/nebby-verdict-routing  -> hotfix/nebby-slack-backoff  (7 commits, not 16)
hotfix/nebby-slack-backoff  -> main                        (escape hatch)
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

# 9. Optional: replace Claude Code's deadline-bound native updater on slow links.
scripts/install-claude-resilient-updater.sh
```

## Resilient Claude Code updates

Claude Code's native updater can abandon a valid 300 MB download when a slow link
exceeds its fixed deadline. `scripts/install-claude-resilient-updater.sh` installs a
macOS LaunchAgent that checks the `latest` channel every six hours. Its worker bypasses
local API proxies for the Google Cloud Storage download, preserves partial files across
DNS and connection failures, resumes them on the next attempt, verifies
the release manifest checksum, and swaps the version symlink atomically. A verified run
also writes Claude's native update-result schema, so `claude doctor` does not keep
reporting an older failed attempt after the replacement updater succeeds.

Run a read-only channel and checksum check at any time:

```bash
~/.local/bin/claude-manual-update --check
```

Logs are stored in `~/.local/state/claude-resilient-updater/update.log`. Existing
versions remain under `~/.local/share/claude/versions` for manual rollback.

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

### Every `gh` call is pinned to origin

The hooks ask GitHub about the branch through `gh`, and every one of those calls passes
`--repo` for the **origin** remote explicitly. Bare `gh` picks a remote by its own
precedence and prefers `upstream` when one exists, so inside a fork it answers about the
*parent* repository.

That is not theoretical. On 2026-08-12 in `Screddyice/backdoor` (a fork of
`ajsai47/backdoor`), an open PR on origin was reported as "no open pull request" and the
Stop hook blocked every stop with no way to satisfy it — the PR existed the whole time,
the hook was simply asking the wrong repo. The same resolution silently made
`auto-pr-push.sh` unable to see merged PRs, defeating its duplicate-PR guard.

Two implementation details are load-bearing, both learned by breaking them first:

- The `--repo` flag is passed as an **array**, never as an unquoted
  `${VAR:+--repo "$VAR"}`. That form relies on word-splitting an unquoted expansion,
  which bash does and zsh does not, so under zsh it collapses into the single argument
  `--repo owner/name` and `gh` rejects it with `unknown flag`.
- The array is expanded as `${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"}`. macOS
  ships bash 3.2, where an empty array expanded under `set -u` aborts with
  `unbound variable` — and `auto-pr-push.sh` runs `set -uo pipefail`. A remote URL that
  failed to parse would otherwise turn a cosmetic miss into a dead hook.

Verify against a fork specifically; a non-fork repo passes either way and proves nothing.

### A rejected push is a failure, not an `[ok]`

`auto-pr-push.sh` used to run `git push` and discard its exit status, then report success from
the branch it took afterwards. A rejected push produced exactly this in the log:

```
 ! [rejected]  HEAD -> feat/be-icp-scoring-rubric (non-fast-forward)
error: failed to push some refs to …/nebos-v2.git
[ok] pushed nebos-v2@feat/be-icp-scoring-rubric (PR already open)
```

Nothing reached GitHub, and the one place you would check to find that out said it had. The
other branch was worse in a quieter way: it read `[warn] push ok but could not open PR`, which
asserts the push succeeded in the middle of reporting a problem. Both were reachable with the
push already rejected, so "the hook says it pushed" carried no information either way.

The exit status is now checked. On failure the hook classifies the cause rather than printing
`git push failed` and sending you into a 30,000-line log to work out which of several unrelated
problems you have:

| Cause | Reported as |
|---|---|
| Remote has commits this checkout lacks | `REJECTED (non-fast-forward) … nothing was uploaded` + the `git pull --rebase` to run |
| No write access | `REJECTED — no write access to <slug>` |
| No usable git credentials | `FAILED — git has no usable credentials` |
| Offline / host unreachable | `FAILED — network unreachable` |
| Server-side branch protection | `REJECTED by a server-side rule` |

Failures also append one line each to **`~/.cache/claude-code-harness/auto-pr-push-failures.log`**.
The main log interleaves raw `git` and `gh` output for every repo on the machine, so a failure
in it is findable only if you already suspect one. The failures file answers "did anything not
make it to GitHub?" with `cat`.

Worth knowing about the non-fast-forward case specifically: the hook does not resolve it. A
diverged branch needs a human to choose rebase, merge, or discard, and a hook that force-pushed
on your behalf would be a much worse bug than the one it replaced.

### A squash-merged branch is not a branch without a PR

The enforcement asks GitHub for an **open** PR. After a squash merge there isn't one: the PR
is `MERGED`, and the squash commit on the base is an ancestor of nothing on the branch, so
`HOOK_AHEAD` stays above zero forever. A branch whose work shipped therefore looks identical
to work that never had a PR, and the Stop hook blocks every stop with no action that can
satisfy it — opening another PR does not help, and deleting the local branch is the only way
out, which nothing tells you.

`hook_load_pr_status` now falls through to `hook_branch_already_merged()` and reports
`merged_pr`, which the enforcers treat as satisfied:

```
open PR found        -> has_pr
merged PR, same head -> merged_pr     (satisfied — work already landed)
neither              -> needs_pr      (blocks)
```

**The check is keyed on the branch's current head SHA**, matching `auto-pr-push.sh`, which
had this guard first. That is what stops a branch coasting: reuse a merged branch for new
commits and its head no longer matches the merged PR, so it correctly needs a PR again.
Both directions are worth testing, because a fix that only satisfies the first one silently
turns the rule off for reused branches.

`merged_pr` is deliberately a separate status rather than reusing `has_pr` — "already
landed" and "has an open review surface" are different facts, and anything that logs or
reports should be able to tell them apart. `enforce-pr-codex.sh` needed no change; it blocks
only on exactly `needs_pr`.

### A head already under review does not get a second PR

The merged-PR guard above asks GitHub about `--head "$HOOK_BRANCH"`, so it only sees PRs opened
under the name currently checked out. Push a branch's HEAD somewhere else and it goes blind:

```
git checkout -b pr44-check origin/fix/first-failure-failover
git merge origin/main            # test the integration
git push origin HEAD:fix/first-failure-failover
```

Those commits are now under review as `fix/first-failure-failover`. The checkout still says
`pr44-check`, which has commits ahead of `main` and no PR of its own, so the hook pushed that
name too and opened a PR for work already in review. Observed 2026-08-25 in
`Screddyice/backdoor`: #51 and #52 appeared for the `pr47-check` and `pr44-check` branches used
to test-merge #47 and #44.

`hook_head_has_pr_elsewhere()` asks a different question — is this exact commit the head of any
PR, under any branch name:

```
open PR, this branch     -> has_pr
merged PR, same head     -> merged_pr        (work already landed)
any PR elsewhere, same head -> pr_elsewhere  (reviewed under another name)
none of the above        -> needs_pr         (blocks)
```

`auto-pr-push.sh` checks it **before pushing**, not just before `gh pr create`. Skipping only the
create still publishes a redundant remote branch, which the Stop hook then demands a PR for.
`enforce-pr-claude.sh` reports `pr_elsewhere` and names the PR instead of blocking, since there is
nothing to open. `enforce-pr-codex.sh` needed no change; it blocks only on exactly `needs_pr`.

A **closed, unmerged** PR is not a match. That work was rejected, and rejected work is not a
review surface.

**The result is shape-checked, and that is load-bearing.** This guard suppresses a pull request,
so every way it can be wrong costs review coverage. A non-empty check is not good enough: the two
older `auto-pr-push` tests mock `gh` with a catch-all that answers an unrecognised `pr list` query
with `0`, and that lone character read as a match and stopped proposing PRs on every branch they
exercise. All three suites went red at once. The guard now demands `#<number> <branch>` and treats
anything else as no match, so a schema change, a deprecation notice on stdout, or an older `gh`
fails toward opening the PR.

### Disposable branches, only when you say so

`HARNESS_PR_SKIP_BRANCHES` holds space-separated globs of branch names the rule ignores:

```
HARNESS_PR_SKIP_BRANCHES='scratch/* tmp/*' claude
```

**Empty by default.** A guessed pattern list would exempt `feat/add-health-check` on its way to
catching `pr44-check`, and the branch that quietly stops being enforced is the one nobody notices.
Most of the time you want the automatic guard above instead — it recognises the same integration
branches without being told, because it looks at what is under review rather than at a name.

Covered by `scripts/test-auto-pr-push-elsewhere-guard.sh` (8 cases: unreviewed work still
proposed, open and merged matches skipped, closed-unmerged still proposed, a reused branch with
new commits, the opt-out matching and not matching, and four shapes of unrecognised `gh` output
that must all fail safe).

### The PR's base is derived, not defaulted

`gh pr create` was called with no `--base`, so GitHub silently used the repository's **default**
branch. Meanwhile `HOOK_BASE` only ever looked for `main`/`master`. Two guesses, and nothing made
them agree with each other or with reality.

Observed 2026-08-17: `teamnebula-ai/nebos-v2#365` opened against `main` in a repo where every PR
targets `dev`. The hook had also counted "commits ahead" against `origin/main`, so a branch cut
from `dev` was reported as 2 ahead when it carried 1 commit.

`HOOK_BASE` now scores candidate integration refs by **total divergence** and picks the nearest,
which is the branch the work actually forked from:

| | ahead | behind | total |
|---|---|---|---|
| cut from `main` → `main` | 1 | 0 | **1** |
| cut from `main` → `dev` | 1 | 1 | 2 |
| cut from `dev` → `dev` | 1 | 0 | **1** |
| cut from `dev` → `main` | 2 | 0 | 2 |

"Fewest commits ahead" is the obvious metric and it ties constantly — a branch cut from `main`
with one commit is 1 ahead of both. Divergence separates them because it also counts what the
candidate has that the branch does not. Derived per branch, so one repo can serve both flows.
`HOOK_BASE_BRANCH` is then passed explicitly as `--base`, so the PR and the precondition can no
longer disagree.

**Remote-tracking refs are scored alone whenever any exist**, with local branch names only as a
fallback. Mixing the tiers is a correctness bug, not a style preference: after a squash merge
`origin/main` carries a commit the branch lacks while a stale local `main` does not, so the local
ref wins on divergence and the "base already contains this tree" guard above stops firing. That
guard is what prevents a second PR for already-merged work, so losing it reopens the llm-jury#18
duplicate. `test-auto-pr-push-merged-guard.sh` case 4 caught exactly this during development.

Both `enforce-pr-*` Stop hooks interpolate `$HOOK_BASE` into their block message, so their
"N commits ahead of X" line becomes accurate as a side effect.

Covered by `scripts/test-auto-pr-push-base.sh` (5 cases: forked-from-dev, forked-from-main in the
same repo, a main-only repo, the ahead-count agreeing with the base, and the stale-local-ref trap).

### A fix pushed over a rejection goes back to the reviewer

GitHub does not clear `CHANGES_REQUESTED` when the author pushes a fix, and it does not re-notify
the reviewer. The review request is spent, the red state stands, and the PR looks the same from
outside whether the work was done or not.

On **2026-08-31** a sweep of `teamnebula-ai` found **eleven** open PRs holding `CHANGES_REQUESTED`,
and roughly two thirds had already been fixed in an earlier session. They were waiting on nothing
but a re-request. Two sessions also wrote the same fix for `hyperscale#94` in parallel, because
neither could see the work was already done.

After a successful push onto a branch that already has an open PR, `auto-pr-push.sh` now
re-requests review. Deliberately narrow, because a review request is a notification to a person:

- **Only reviewers whose current state is `CHANGES_REQUESTED`**, not the default roster. A
  rejection is a conversation with one person. Routing the fix to someone else makes them
  re-derive context the original reviewer already has, and leaves that reviewer's request looking
  ignored. Latest-state-per-person, so someone who rejected and later approved is not re-asked.
- **Never the PR author.** GitHub answers 422, and a self-rejection would otherwise ping you about
  your own branch.
- **Once per head SHA.** This hook runs after every Bash call; without the stamp under
  `~/.cache/claude-code-harness/` one session would notify the reviewer dozens of times.
- **A failed re-request is loud**, appended to `auto-pr-push-failures.log`. The silent version of
  that failure is the original bug: a fixed PR nobody has been told about is indistinguishable
  from an unfixed one.

Covered by `scripts/test-auto-pr-push-rerequest.sh` (7 cases, pushing against a local bare remote
because the re-request runs after the push that `AUTO_PR_PUSH_DRYRUN` returns before).

### `rejected-prs.sh` — which rejections are actually waiting on you

```
scripts/rejected-prs.sh                 # your open PRs, every repo
scripts/rejected-prs.sh teamnebula-ai   # one owner
scripts/rejected-prs.sh --author noya   # someone else's
```

`gh search prs` **cannot** return or filter `reviewDecision` — it is not in that command's schema,
and a GraphQL search reaching for it alongside `reviews` and `statusCheckRollup` times out on a few
dozen PRs. So this searches for the repositories cheaply, then asks each repository separately.

`CHANGES_REQUESTED` on its own is not a to-do item, so each PR is classified by what happened
after the rejection:

| State | Meaning |
|---|---|
| `needs-work` | No commits since the rejection. Work is outstanding. |
| `fixed?` | Commits landed, but the rejecter was never asked to look again. Read the diff before rewriting anything. |
| `resubmitted` | Commits landed and the rejecter holds a live review request. Waiting on them. |

The question mark on `fixed?` is deliberate: commits after a rejection are evidence someone
worked, not proof they addressed the review.

Covered by `scripts/test-rejected-prs.sh` (5 cases). One of them pins a bug worth naming, because
it was silent and wrong in the expensive direction: the commit count was fetched with
`gh api --jq --arg since …`, and `gh api` has no `--arg` flag, so jq read `"$since"` as a filter
and matched nothing. Every PR reported zero commits since its rejection and came back
`needs-work`, including eleven that had just been fixed. A tool that says "needs work" about
finished work does not fail safe — it causes the duplicate.

## gbrowse — headed browser sessions that survive

`browse handoff` opens a visible browser so a human can log in, solve a CAPTCHA, or
clear an MFA prompt. In a Claude Code session it reliably destroys the thing it just
created. Observed 2026-08-14 driving the GoDaddy and Squarespace panels: five daemon
deaths, three logins, every one discarding the authenticated session.

```bash
gbrowse handoff [message]   # headed takeover that actually survives
gbrowse doctor              # mode agreement, orphaned daemons, watchdog risk
gbrowse <anything else>     # passed straight through to browse
```

**Cause.** `handoff` promotes a *running* daemon in place: `browser-manager.ts` swaps
the Playwright context and sets `connectionMode = 'headed'` without restarting the
process. The parent-process watchdog registered at boot (`server.ts:687-714`) is still
live and still pointed at whatever shell started the daemon. Claude Code's Bash tool
kills that shell after every tool call, so on the next 15s poll the watchdog sees a
dead parent, sees headed mode, and shuts down. In headless mode it deliberately stays
alive — promotion is what turns a tolerated condition into a fatal one.

A second path shares the predicate: the SIGTERM handler at `server.ts:1369-1381` also
quits when runtime mode is headed, gated by **neither** `BROWSE_PARENT_PID` nor
`BROWSE_HEADED`. Exporting `BROWSE_PARENT_PID=0` therefore only silences the poller.

**Fix.** `browse connect` already does the right thing: it force-kills any existing
daemon and cold-restarts with the watchdog disabled and the process detached into its
own group. So `gbrowse handoff` captures the current URL, routes through `connect`,
and re-navigates. Cookies survive because the Chromium profile is persistent.

`gbrowse doctor` reports the tell that makes this invisible: the state file's `mode` is
written only at start, so after an in-place promotion disk says `launched` while the
process is headed and dying on a timer. It also lists orphaned daemons, which `connect`
cannot see because it only kills what the state file knows about.

Verified: plain `browse handoff` daemon gone after 45s; via `gbrowse`, alive with
consistent mode. Patching the gstack checkout directly is not durable, because
`/gstack-upgrade` hard-resets the working tree to origin/main, so the wrapper lives
here and the real fix is a separate PR upstream.

### browse-watchdog — notice, restore, file evidence

`gbrowse` fixes the handoff path; `scripts/hooks/browse-watchdog.sh` covers every
other way the session dies. Observed 2026-08-20 driving the IPRoyal dashboard: three
daemon deaths in one session, one of which discarded a logged-in purchase flow. The
worst part was not the crash — it was that the CLI silently auto-started a
replacement server in `launched` mode on a different port with a clean profile, so
every later command drove a browser nobody was looking at, and a dry run against
production proxies read the *old* environment and returned wrong verdicts.

```bash
scripts/hooks/browse-watchdog.sh <project-dir> &   # watch that repo's session
touch <project-dir>/.gstack/watchdog-stop           # stop it
```

Every `WATCHDOG_INTERVAL` (20s) it checks three things that must agree: the state
file exists, its pid is alive, and `browse status` answers `Mode: headed`. Split
brain in any direction is treated as a crash. On crash it captures evidence (state
file, process table, port 34567 holders, connect-log tails), restarts with the same
cleanup sequence that works by hand, navigates back to the last URL it recorded
while healthy, and commits the evidence to the rolling `crash-reports` branch —
one draft PR collects all of them, so a flapping server cannot spam the repo.
`WATCHDOG_MAX_RESTARTS` (4/hour) stops the loop when the server needs a human
rather than a supervisor. It never auto-fixes: gstack is third-party, and an
unattended "fix" for an arbitrary crash is how you get two bugs.
`WATCHDOG_AUTOFIX=1` additionally asks a headless `claude -p` to append an
analysis to the report — analysis, not a merge.

## Automated PR review

[Shawns QA Assist](https://github.com/Screddyice/shawns-qa-assist) reviews pull
requests here, repairs what it finds, and merges once its gate passes.
`.shawns-qa.toml` points at `scripts/verify.sh`, which parses every tracked
shell and Python file.

Without that gate the agent reports `merge_eligible=false` and hands **every**
PR to a human, because nothing can vouch for the change. That is what happened
to #29 and #30.

The gate is syntax only, on purpose. This repo has no test suite, and a gate
that failed on pre-existing style would block every PR on faults it did not
introduce. What it does catch is the failure that actually costs something here:
a broken hook reaching `main` and then dying inside somebody's session.

```bash
bash scripts/verify.sh   # exits non-zero and names the file on a syntax error
```

To pause the agent on this repo:

```toml
[behavior]
enabled = false
```

## DNS Cutover Guards

Moving a domain's DNS is not a website setting when that domain also carries email.
`reddy2help.org` was moved from Squarespace to GoDaddy on 2026-08-14 and went fully
offline, mail included, because nothing asked whether the delegation was signed.

```bash
scripts/dns-preflight.sh  <domain> <target-nameserver> [more...]
scripts/dns-postflight.sh <domain> --expect-ip <ip> --dkim-fingerprint <sha256> \
                                   --acme-host <ssh-alias> [--acme-service caddy]
```

**The rule both scripts enforce: build the destination zone first, switch last.** A
zone at a new provider is inert until the nameservers point at it, so it can be built
and verified at zero risk. Switching first is not a faster path to the same place.

`dns-preflight.sh` is read-only and exits non-zero on a blocking finding. It catches
the three failures that take a domain fully offline:

- **A destination that does not exist.** Providers commonly run their advertised
  nameservers as open recursive resolvers, so querying one for a domain it does not
  host resolves through the public internet and hands back the CURRENT zone at the
  OLD provider. Every record then "matches", and the pre-flight passes a destination
  that was never built. Measured on `reddy2help.org` against
  `ns0{1..4}.squarespacedns.com`: A, MX, SPF and the DKIM fingerprint all matched
  byte-for-byte while the Squarespace panel showed its own parking IPs. Cutting over
  on that evidence points the apex at `198.185.159.x` — site down, mail unverified.
  The gate compares the SOA's primary (MNAME): a server echoing the source returns
  the source's MNAME, one actually hosting the zone returns its own. **Not** the `aa`
  flag — real anycast nameservers answer `+norecurse` with REFUSED and no `aa` even
  for zones they serve, so an `aa` gate rejects legitimate destinations.

- **DNSSEC.** If the registry publishes a DS record, a nameserver move to an unsigned
  provider means the registrar disables signing immediately while the DS leaves the
  registry on its own TTL. In that gap every validating resolver refuses the answer.
  Measured: SERVFAIL on 1.1.1.1, 8.8.8.8 and 9.9.9.9 within a minute, for ~11 minutes.
- **Mail records absent at the destination.** A new zone inherits nothing. The
  destination is queried directly and diffed against the live zone. The DKIM key is
  **fingerprinted**, not merely counted: a key over 255 characters is published split
  across quoted strings, and rejoining it wrong yields a record that is present,
  well-formed, and cryptographically junk. Mail keeps sending and silently fails
  authentication.

`dns-postflight.sh` catches the three that make a *correct* cutover still serve nothing
— or look broken when it is fine:

- **Staged propagation.** The NS change and the DS removal reach the registry
  independently, so it polls four validating resolvers rather than one.
- **A vantage point that lies.** Everything a recursive resolver says is cache, not
  zone content: a deleted record keeps resolving for its full TTL, and a just-added
  one does not appear at all. Worse, on a host behind a VPN resolver or a local DNS
  proxy, `dig @some.nameserver` may never reach that nameserver — port 53 is
  intercepted and answered from cache whatever `@server` is given. Measured on
  2026-08-25: `os.reddy2help.org` read as NXDOMAIN on all four delegated nameservers
  *and* on the previous provider's, and the record had been published and serving the
  entire time. So the post-flight proves the delegated nameservers are answering for
  themselves before believing anything they say, and reads the apex, MX, SPF and DKIM
  from authority rather than from a resolver. It also flags the inverse — resolver and
  authority disagreeing — which is the stale-cache case that hides a deleted record.

  This gate **is** the `aa` flag, which the pre-flight deliberately rejects, and the
  difference is the direction of the test. Before cutover the destination zone is
  inert and not yet delegated, so a legitimate nameserver may answer `+norecurse` with
  REFUSED and no `aa`; gating on `aa` there rejects good destinations. After cutover
  the delegated nameservers genuinely host the zone, so `aa` is exactly what they must
  set — and an interceptor cannot forge it, because it sets `ra` and omits `aa`.

  The flag test reads the parsed flag field, not a substring of the header line.
  The last flag is followed by `;`, not a space, so matching `" ra "` against the raw
  line silently never fires — which is how this check was unreachable on its first
  pass, failing closed and printing no reason.
- **A stuck ACME backoff.** An ACME client cannot observe that DNS changed. Caddy had
  been failing since the VM was built and by cutover was on attempt 33 with a
  **six-hour** retry, having fallen through to Let's Encrypt staging (browser-rejected).
  DNS was right, mail was right, the site served nothing. `--acme-host` restarts the
  service and the issuer is checked afterwards so a staging cert cannot pass.

  The HTTPS checks bypass `HTTPS_PROXY`. curl honours it and resolves the name **at
  the proxy**, so `--resolve` is ignored and a proxy that cannot resolve returns 502 —
  indistinguishable from the origin being down, with nothing in the error naming the
  proxy. That 502 was read as an outage on 2026-08-25 while the origin served 200.

The `dns-cutover` skill wraps both with the procedure and the DNSSEC-restore ordering
rule (**sign first, publish the DS second**).

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

## Durable Cognee writes

`scripts/cognee-remember-durable.sh` wraps the Cognee plugin's `cognee-remember.sh` so
an explicit memory write cannot vanish silently. Cognee returns `ok` the moment a write
is queued and then holds it in process memory until the cognify pipeline reaches it; a
restart in that window drops the write with no error anywhere. On 2026-09-03 an evening
of acknowledged writes was lost exactly that way, to a watchdog that restarted the
container hourly.

The wrapper journals the content under `~/.cognee/outbox` keyed by its MD5, sends it
through the plugin, then verifies it landed by listing the dataset: Cognee names every
raw file `text_<md5(content)>.txt`, so one list call answers without touching the
pipeline lock. If the row is not there inside `COGNEE_DURABLE_WAIT` (60 s), the entry
stays in the outbox and a detached drainer re-checks every `COGNEE_DURABLE_POLL` (300 s),
re-sending after `COGNEE_DURABLE_RESEND` (1200 s) of silence, up to
`COGNEE_DURABLE_MAX_ATTEMPTS` (6) or `COGNEE_DURABLE_MAX_AGE` (6 h). Cognee de-duplicates
identical content, so a re-send of something that did land later is harmless.

```bash
scripts/cognee-remember-durable.sh "fact to keep" --node-set project_docs
scripts/cognee-remember-durable.sh --file notes.md --node-set user_context
scripts/cognee-remember-durable.sh --status        # what is still pending
scripts/cognee-remember-durable.sh --drain --once  # one manual pass over the outbox
```

Output is one JSON line: `stored: true` means the row exists on the server now;
`queued: true` means the drainer owns it. Configuration comes from `~/.cognee/.env`
(`COGNEE_BASE_URL`, `COGNEE_API_KEY`, `COGNEE_PLUGIN_DATASET`), with `COGNEE_OUTBOX` and
`COGNEE_REMEMBER_BIN` as overrides. `~/.claude/scripts/cognee-remember-durable.sh` is a
compat wrapper that execs the copy here. `scripts/test-cognee-remember-durable.sh` runs
both paths against a fake Cognee with no network.

## Optional Hooks

Codex supports lifecycle hooks including `SessionStart`, `Stop`, tool hooks, and
compaction hooks. This harness includes `examples/hooks.json.example` for users who
want auto-init behavior similar to the old Claude SessionStart hook. Codex requires
non-managed hooks to be reviewed and trusted; inspect them with `/hooks` after install.

The `scripts/hooks/` directory is the canonical runtime for hooks shared by Claude Code
and Codex. Point each tool's config at this directory instead of keeping executable
copies under `~/.claude` and `~/.codex`. Both run the same automatic PR tracker and the
local Ollama diff reviewer. Thin Stop-hook adapters preserve each tool's JSON contract:

| Behavior | Claude Code | Codex |
|----------|-------------|-------|
| Push branches and open draft PRs | `auto-pr-push.sh` | `auto-pr-push.sh` |
| Enforce one PR per work branch | `enforce-pr-claude.sh` | `enforce-pr-codex.sh` |
| Review the current diff with Ollama | `local-diff-review.sh` | `local-diff-review-codex.sh` |
| Distil session left-off into HyperSwarm | Claude settings | `codex-hyperswarm-leftoff.sh` |
| Sample OAuth login expiry | `oauth-expiry-monitor.sh` | n/a |
| Write a session memory to Mem0 | plugin hooks | plugin hooks |

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
(`--quiet`). It stays silent while your login is healthy. Codex authenticates through its
own CLI, so this hook is Claude-only.

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

#### Session memories

Every host contributes memories to **Cognee** (migrated from Mem0 on 2026-08-20):
Claude Code runs the `cognee-memory@cognee` plugin, Codex runs `cognee@cognee`, and
Hermes writes through a native Python provider at `~/.hermes/plugins/cognee/`. All three
share one dataset, `agent_sessions`, tagged by node set (`user_context`, `project_docs`,
`agent_actions`).

Mem0 was retired because its Starter plan capped **retrievals** at 5,000/month and a
single `user_id` shared across every host exhausted that quota, after which the API
returned HTTP 402 on every call. The lesson generalises: one shared memory account
across many hosts is a quota single point of failure, so watch the retrieval ceiling
rather than the add ceiling.

HyperSwarm's `mem0_session` distiller matches on `metadata.session_id`, so any
host that wants a corpus entry has to tag its session write with that key.

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

Because Claude Code and Codex both run this same script — Claude via settings, Codex via
`~/.codex/hooks.json` — the guard applies to both. Run
`scripts/test-auto-pr-push-merged-guard.sh` after changing it.
The old top-level `scripts/codex-local-diff-review.sh` remains as a compatibility entry
point. Run `scripts/test-shared-hooks.sh` after changing shared logic or an adapter.

## Workspace root (multi-org)

When this harness is installed on a multi-org machine (e.g. Shawn's `~/projects`), hooks and
skills are **user-global**. Opening Claude Code or Codex from the workspace root or
from any org/repo under it uses the same harness. Workspace docs: `~/projects/CLAUDE.md`,
`~/projects/AGENTS.md`. Org folders only add thin pointers; git `origin` selects company
credentials.

| Harness | Workspace entry points |
|---------|------------------------|
| Claude Code | `~/projects/CLAUDE.md`, `~/projects/.claude/skills` → `~/.claude/skills` |
| Codex | `~/.codex/AGENTS.md` + `~/projects/AGENTS.md`; skills under `~/.codex/skills` (agents skills linked); hooks in `~/.codex/hooks.json`; zsh `codex` loads `~/projects/.env` |

## Retired: Grok harness support

The Grok Build TUI, `~/.grok`, and this repo's Grok slice — `scripts/install-grok-harness.sh`,
`scripts/grok/`, `examples/grok/`, and `enforce-pr-grok.sh` — were removed on 2026-08-18.

One finding from that host still governs this repo: never import a harness's full hook chain
into a second harness's per-tool-call path. Doing that ran the Ollama diff reviewer on every
Grok tool call and kernel-panicked this Mac twice on 2026-07-31, which is why the reviewer's
resident cost is capped below.

## Local Ollama diff reviewer

### GPU cost

The reviewer runs on `Stop`, so it fires once per turn. It used to default to
`gemma3:12b` with no rate limit, which meant a 13 GB load onto the GPU dozens of
times in a working session. Two defaults changed on 2026-07-31:

| Setting | Default | Purpose |
|---------|---------|---------|
| `LOCAL_REVIEW_MODEL` | `qwen3.5:4b` | Small model instead of `gemma3:12b`'s ~13 GB |
| `LOCAL_REVIEW_KEEP_ALIVE` | `30s` | Unload after the review instead of holding GB between turns |
| `LOCAL_REVIEW_COOLDOWN_SECONDS` | `1200` | Skip if this repo was reviewed less than 20 minutes ago |
| `LOCAL_REVIEW` | `1` | Set to `0` to disable the reviewer entirely |

#### Durable memory for the reviewer

The reviewer reads prior-work notes for the changed files out of the offline Mem0
mirror (`~/.mem0-local/cache.db`) and prepends them to its system prompt, so it reviews
a diff knowing what was decided about those files before.

> **Post-migration note (2026-08-20).** This path still reads the Mem0 mirror, which is
> now a **frozen archive** — it holds 16,127 memories and keeps working offline, but it
> no longer receives new writes, so the reviewer's context ages from here. Repointing
> `local-diff-review.sh` at Cognee is tracked separately; the hook was deliberately left
> alone during the migration because the mirror is local-only and never touched the
> quota that forced the cutover.

Every other local brain gets this at the proxy: `src/proxy/memory.py` in
`Screddyice/backdoor` injects recall into anything routed through `:8083`, which covers
`qwen` lean/fast, `qwen full`, `/model qwen`, and cloud→local failover. This hook calls
Ollama directly, so none of that reached it, and it was the last local model in the
stack running with no memory at all.

Sending the review through the router would have fixed it in one line and cost two
things the hook cannot give up. `keep_alive` becomes the router's to choose when the
hook needs `30s` — holding 7.5 GB between turns is the behaviour that panicked this host
twice. And a `qwen*` model name maps onto the heavy tier, so every Stop would load 17 GB
instead of the 4B's 7.5 GB. Reviews would also start depending on the router being up,
when today they only need Ollama. So recall is read here from the same mirror, under the
same rules the proxy follows: local SQLite only (no Mem0 API call, so no quota and it
works offline), budgeted, and fail-open.

| Setting | Default | Purpose |
|---------|---------|---------|
| `LOCAL_REVIEW_MEMORY` | `1` | Set to `0` to review without durable memory |
| `LOCAL_REVIEW_MEMORY_CHARS` | `1500` | Character budget for the whole injected block |
| `LOCAL_REVIEW_MEMORY_MAX_FILES` | `5` | Cap on how many changed files get a recall call |
| `LOCAL_REVIEW_MEM0_BIN` | `~/.local/bin/mem0-local` | Path to the mirror CLI |
| `LOCAL_REVIEW_DUMP_PROMPT` | `0` | Print the assembled system prompt and stop before inference |

Memory is deliberately a footnote to the diff, not a competitor for it: `num_ctx` is
24576 and the diff can run to 60 KB. `mem0-local filectx` only returns memories that
name the file in question, so reviewing one script does not drag in the rest of the
corpus. Every failure degrades to a plain review rather than blocking one — a missing
binary, a locked database, a recall that hangs (3s per file), or a budget too small for
one block all just drop the memory and review anyway.

`LOCAL_REVIEW_DUMP_PROMPT=1` prints the prompt and exits before touching Ollama, which
is how to inspect the wiring without loading a model onto a host that may already be
holding one.

Run `scripts/test-local-diff-review-memory.sh` after changing anything above. It stubs
`mem0-local` and asserts on the assembled prompt, so it needs neither Ollama nor the real
corpus.

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

The same bar applies to crash evidence on the rolling `crash-reports` branch: captured
logs are redacted before they are pushed. Browse server token fields, crashpad API-key
arguments, and exported environment key lines are replaced with `REDACTED` markers, and
the branch history is rebuilt rather than amended when a leak slips through, since a
follow-up commit leaves the exposed value reachable in prior commits.

## License

[MIT](LICENSE)
