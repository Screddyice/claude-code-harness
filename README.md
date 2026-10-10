> **claude-mem is the only memory layer on this machine.** See "Memory" below.

# claude-code-harness

This repository carries the Claude Code side of the local agent setup: Claude hooks,
status tooling, and shared utilities.

Codex has a separate source of truth in [`Screddyice/codex-harness`](https://github.com/Screddyice/codex-harness).
Keep Codex configuration and Codex plugin manifests there. This repository does not
install or register Codex plugins.

Runtime logs for the GUI environment LaunchAgent live under `~/.local/state/`; the example stays independent of optional learning or project-specific directories.

## What's Inside

```
claude-code-harness/
├── examples/
│   ├── AGENTS.md.workspace.example   # ~/projects/AGENTS.md template
│   ├── AGENTS.md.project.example     # per-repo AGENTS.md starter
│   ├── com.screddy.gui-env.plist     # LaunchAgent that runs set-gui-env.sh
│   └── com.screddy.kernel-zone-watchdog.plist
├── scripts/
│   ├── verify.sh                     # parses every tracked shell and Python file
│   ├── audit-stale-instructions.sh   # finds docs that present a retired component as current
│   ├── install-claude-resilient-updater.sh # resumable Claude native updates on macOS
│   ├── claude-manual-update             # checksum-verified update worker
│   ├── statusline.sh                     # Claude model and session status source
│   ├── test-statusline.sh                # status-line fixture tests
│   ├── hooks/                        # capture gate, manual team-context sync, login-expiry and browse watchdogs
│   ├── mcp-headers.py                # MCP auth headers read from the environment at call time
│   ├── set-gui-env.sh                # publishes named keys into the macOS GUI domain
│   ├── team-context-pull.sh          # pulls team-context and re-applies personal settings
│   ├── swarm/                        # cross-CLI parallel agent dispatch engine
│   ├── test-swarm.sh                 # swarm pytest suite runner
│   ├── track-branch-pr.sh             # pushes a branch and opens/updates its draft PR
│   ├── gbrowse                       # headed-browser wrapper that survives a session
│   ├── qwen                          # defaults to local 4B; explicit 27B keeps admission guards
│   ├── test-qwen.sh                  # admission, lock and lease tests (loads no model)
│   ├── dns-preflight.sh              # what breaks if I move this domain's DNS now
│   ├── dns-postflight.sh             # did the cutover land, and did mail survive
│   ├── kernel-zone-watchdog.sh       # catches a kernel zone-map leak before it panics the Mac
│   └── test-kernel-zone-watchdog.sh  # watchdog unit tests (parsing, thresholds, snapshots)
```

## team-context memory sync (manual)

`scripts/hooks/team-context-autosync.sh` commits and pushes `memory/` and `projects-context/` in
`~/TeamNebula/team-context` to whatever branch that repo is on. It runs only when you call it,
which is what `/tmn-sync` does. Do not register it as a Stop or SessionStart hook: automatic
context capture for Team Nebula was retired on 2026-10-09, and context changes now go up as
individual PRs.

```bash
scripts/hooks/team-context-autosync.sh status   # branch, pause state, pending, recent runs
scripts/hooks/team-context-autosync.sh now      # sync immediately
scripts/test-team-context-autosync.sh           # run after changing the script
```

## Claude starts in bypass-permissions mode

Typing `claude` opens a session with `permissions.defaultMode` set to `bypassPermissions` and
`skipDangerousModePermissionPrompt` on, so no tool call waits for approval and there is no
startup confirmation. Shift+Tab still switches modes inside a session.

Both config dirs carry it, because which one loads depends on how Claude starts:

| Launch | Settings file read |
|---|---|
| `claude` in a shell (`.zshrc` exports `CLAUDE_CONFIG_DIR`) | `~/TeamNebula/team-context/settings.json` |
| Desktop app, or any process without that variable | `~/.claude/settings.json` |

team-context's `settings.json` is tracked and shared with the team, so the personal values live
in `~/.claude/team-context-settings.overlay.json` (template:
`examples/team-context-settings.overlay.json`) and never get committed there.
`scripts/team-context-pull.sh` pulls team-context `main` and layers the overlay back on;
`apply` re-layers it without pulling. A local edit that is in neither the tracked file nor the
overlay stops the pull, so nothing is lost silently.

```bash
cp scripts/team-context-pull.sh ~/.claude/scripts/
cp examples/team-context-settings.overlay.json ~/.claude/team-context-settings.overlay.json
~/.claude/scripts/team-context-pull.sh apply
scripts/test-team-context-pull.sh
```

What this gives up: permission prompts and the auto-mode classifier no longer stop merges,
pushes, deletes or sends. The team-context PR guard is a hook, not a permission rule, so it still
checks `git push` and `gh pr create`. RS21 and the other rules in `~/.claude/CLAUDE.md` still
apply, but nothing in the harness enforces them. To go back, set `defaultMode` to `auto` in both
places and rerun `apply`.

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
while sharing one Claude Code setup.

## Standalone local Qwen agent

`qwen` starts **Qwen Code**, an independent coding agent connected to the local
Ollama model. It can read and edit files, execute terminal commands, run builds,
and retain sessions without launching Claude Code or Codex. Run it from the
project directory. The default model is `qwen3.5:4b-256k`. Type `qwen 27b`
to select **`qwen3.8:27b-obliterated`**; the 27B selector never chooses a stock
model. `qwen raw` provides plain chat without execution tools.

Install Node.js 22+ and run `bash scripts/install-qwen-code.sh` once. The installer
pins Qwen Code 0.23.4 in `~/.local/share/qwen-code`; its npm binary does not replace
the guarded `~/.local/bin/qwen` launcher.

| You type | You get |
|---|---|
| `qwen` | interactive standalone Qwen Code on 4B |
| `qwen 27b` | standalone agent on Qwen3.8 27B OBLITERATED |
| `qwen 27b claude` / `qwen 27b codex` | alternate clients on the same obliterated 27B |
| `qwen agent` or `qwen code` | the same standalone agent |
| `qwen "build this project"` | one-shot agent task |
| `git diff | qwen` | an agent task using stdin |
| `qwen --continue` | the latest agent session for this project |
| `qwen code --help` | Qwen Code options, approvals and MCP configuration |
| `qwen raw` | plain Ollama chat |
| `qwen claude` / `qwen codex` | explicit alternate agent clients |

The launcher reuses the existing model admission guard and compute lease. It
sets the local OpenAI-compatible endpoint and a placeholder key. The checked-in
`config/qwen-code-local.json` supplies 262,144-token context accounting, a
4,096-token response cap, local-provider timeouts and disabled telemetry. It
compacts at 80% of the provider window and leaves Qwen Code's own turn guards
in charge (see "Autonomous runs" below). These are system defaults: Qwen Code
user/project settings can override them. No
cloud fallback is configured. The installed 4B tag also sets `num_ctx` to
262,144. The launcher estimates KV memory for that window before loading it and
may refuse a session when the Mac lacks headroom. An explicit `27b` selector
keeps its 32K client window and overrides `QWEN_MODEL`.
`QWEN_CODE_BIN` overrides the installed executable path.

Admission follows the active Ollama service limit. On macOS the launcher reads
`OLLAMA_CONTEXT_LENGTH` from the `com.screddy.ollama` launchd job, so a model tag
that advertises a 256K window does not get charged for 256K when the server caps
the runner at 32K. `OLLAMA_CONTEXT_LENGTH` in the client environment remains an
explicit override.

The same file keeps Qwen Code's startup prompt near 11K tokens. With stock
settings a session in `~` opened at 21,895 tokens of a 32,768-token window, so
compaction fired on the first tool result and the model lost track of commands
it had just run, which tripped the loop detector. Stock settings also ran a
17.5K-token memory-extraction pass and a 6.7K-token memory "dream" after turns,
queued on the same single Ollama slot as the session. The defaults now:

| Setting | Tokens saved |
|---|---|
| `skills.disabledLevels: ["user", "bundled"]` drops 96 skill descriptions; project skills still load | ~7.5K |
| `memory.enableManagedAutoMemory` and `enableManagedAutoDream` set to false | ~1.2K, plus both background passes |
| `tools.toolSearch.threshold: 0` and a shorter `tools.eager` list defer `skill`, `web_fetch`, `monitor`, `zoom_image` and `task_stop` behind `tool_search` | ~2K |
| `permissions.deny: ["notebook_edit"]` | ~0.3K |

Measure a change the same way: point `OPENAI_BASE_URL` at a stub server that
saves request bodies, then send the saved `messages` and `tools` to Ollama's
`/api/chat` with `num_predict: 1` and read `prompt_eval_count`.

### Repeated searches and reads

The launcher installs a progress hook through its system defaults. After the
same search or file read returns unchanged content twice within the last 12
inspections, the hook denies another identical inspection and tells the model
to change its search or proceed to an edit and test. It compares tool arguments
without descriptions, and result content without call IDs or shell PGIDs, so an
interleaved malformed call does not reset it. Changing results remain eligible.
A successful file edit or a new user prompt resets this history, but not the
read coverage described under Re-reading cleared pages. Compute-owner
checks recognize `qwen` and case variants such as `Qwen`, so a capitalized
launcher keeps the same active-session protection.

For simple `grep`/`rg` commands (including `cd path && grep ...`), the hook
recognizes quoted regex alternatives such as `"TypeA\|TypeB"` as search
arguments. These searches receive the same repeat protection after successful
matches. Read-only `&&` chains of searches, `git log`, and `git status`, with
`cd` or `echo` separators, also receive repeat protection. Chains containing
builds or mutations use the general shell backstop below. The hook explains exit code 1
without a reported error as no matches. After two ignored
redirects, it stops the turn. A headless `qwen goal` can then use its existing
fresh-session retry; an interactive session should restart with a bounded
objective and a checkable completion condition. The hook never grants tool
permission, runs a replacement command, or changes model sampling. It stores
only hashes in `~/.cache/qwen/progress/`. Restart Qwen after installing launcher
changes; an already-running client keeps its loaded hooks.

All other shell commands, including pipelines, have a four-result backstop.
Four unchanged outputs for identical arguments within the recent window cause
a redirect before the fifth execution. Two ignored redirects stop the turn.
This covers `grep ... | head && echo ... && grep ...` without requiring the
hook to recognize its syntax. A changed result breaks the identical-output run;
a successful `edit`/`write_file` or a new user prompt resets history. Deliberate
unchanged polling and repeated identical builds can also trigger this limit.
This bounds repetition; it does not prove the model can complete the task.

### Re-reading cleared pages

The 24,000-char clearing threshold (see the settings table under Autonomous
runs) leaves each request with your last four tool results. Qwen Code clears
old output before it adds the newest result, so three survive and the fourth
arrives fresh. One `read_file` page holds up to 8,000 chars. A 1,065-line
README takes nine reads, and by the fifth the first page shows as
`[Old tool result content cleared]`.

On 2026-09-20 a session in `TMN/hypercrawl` spent 70 minutes in that loop. Qwen
read a 184-line build plan, paged through the README, lost the plan, read the
plan again, lost the README, and kept going until the user cancelled. The repeat
guard never stopped it: each pass shifted the offset by a line (`133` then
`134`, `973` then `974`). When the user wrote "stop inspecting and start
building", the new prompt reset the guard's history, and the next pass began
with `package.json`.

The hook now records which lines each `read_file` showed, keyed by a digest of
the real path plus the file's mtime and size:

- It refuses a page-sized read that starts inside lines this session already
  saw, whatever the offset or limit. The refusal tells the model to grep for
  the fact it needs or to make the edit.
- It refuses a fifth page of one file, because that page would clear the first.
- After the first page of a file that needs more than four pages, it tells the
  model to grep instead of paging.
- It allows reads with a limit of 80 lines or fewer, because an edit needs the
  exact current text.
- Editing a file changes its mtime or size, which lets the model read it again.
- A new user prompt keeps the coverage, since cleared output stays cleared.

Three refusals in a row stop the turn. Any tool that runs between refusals
resets the count, since running it means the model took the redirect. Replayed
through the hook, the 2026-09-20 calls draw a refusal at the first README
re-read and stop at call 12 even if the model ignores every redirect.

Hand Qwen a plan as `@plan.md`. That puts the file in your message, and Qwen
Code clears only tool output, so the plan stays visible after the pages around
it are gone. A bare path makes Qwen fetch the file with `read_file`, and that
output gets cleared like any other.

Run `python3 scripts/test-qwen-progress-guard.py` for the regression suite,
which includes the 2026-09-20 replay. Set `QWEN_CODE_TEST_BIN` to an installed
Qwen Code `cli.js` and run `python3 scripts/test-qwen-progress-runtime.py` to
verify recovery and stopping through the real client against a deterministic
local API, without loading a model. It covers repeated searches and re-read
loops, and checks that `@path` content survives clearing.

### Autonomous runs

For plan-driven work, retain the plan outside disposable tool results:

```bash
qwen --plan "/path/to/build-plan.md"
# or a bounded headless task:
qwen code --plan "/path/to/build-plan.md" -p "Implement the first unfinished step and run its focused test."
```

`--plan` appends a startup snapshot as labeled reference data to persistent
session context. The installed client retains it when old tool output clears.
It also directs the agent to implement and verify one supported step before
expanding scope. Files must be nonempty UTF-8 text, at most 24,000 bytes; larger
plans need a phase-sized excerpt. Missing or invalid plans refuse startup before
loading a model. Put this launcher option before client options such as `-p`.
Plan edits after startup require a fresh session or an explicit reread. This mode
supports the normal/code/agent entry points; it does not change `qwen goal`.
macOS and Ollama own memory admission. Persistent context fixes plan eviction; it
does not guarantee that a model will complete an arbitrary build.

Give Qwen a Goal and it keeps working until it proves the goal is met:

```bash
qwen 27b goal -y "Make every test in tests/ pass. Done means pytest exits 0."
qwen 27b                  # interactive: type /goal <objective> in the session
```

`/goal` re-prompts the model after every turn until it calls `update_goal` with
evidence, and a verifier checks that evidence before the Goal counts as done.
State a done condition a command can check. `-y` approves every tool call,
shell included, so run it only in a directory you can throw away or reset.

`qwen goal` runs that headless, prints each tool call and every Goal status
change, and writes the raw stream to `~/.cache/qwen/goals/`. When an attempt
ends without a verified completion (a loop halt, a paused or usage-limited
Goal, a crash) it starts the same objective in a fresh session, up to
`--attempts` / `QWEN_GOAL_ATTEMPTS` (default 3). The files keep every earlier
attempt's edits. It exits 0 on a verified completion, 2 on a verified blocked
Goal, and 1 when the attempts run out. It holds the compute lock and lease
across attempts.

A fresh session is the retry because resuming a stalled one did not work. One
run fixed 8 of 10 failing tests, stalled on invalid `read_file` calls, and hit
Qwen Code's guard against five identical calls in a row. Resuming that session
with `--continue` ran 14 minutes on the last one-line bug without editing it.
Real Qwen Code on the same files in a new session fixed it in 7 tool calls, and
the Goal ended verified `complete` in 476 seconds. Sampling was not the cause:
30 replays of the stalled moment at temperature 0.2 and at Qwen's published
thinking-mode settings (0.6, top_p 0.95, top_k 20, repeat_penalty 1.0), with
and without a think-first instruction, gave the same result.

A live `qwen 27b goal -y` run on a fresh copy of the six-bug fixture finished
verified `complete` on its own, 63 minutes after launch:

| Attempt | Tool calls | Ended |
|---|---|---|
| 1 | 9 | Its first edit dropped the colon from `for line in lines[1:]:`. It re-read `parser.py` until the repeat guard stopped it. |
| 2 | 44 | Fixed the syntax error and the remaining bugs, so all 11 tests passed, then called `update_goal` with `evidence_refs` instead of `evidenceRefs` seven times until the guard stopped it. |
| 3 | 19 | Re-ran the tests, cited them, and the 4B verifier accepted. |

Both stalls were malformed output rather than wrong reasoning. Keep the tag's
`repeat_penalty 1.15`; it is not the cause. A single-state replay first
suggested it was (3 of 9 loop edits dropped the colon at 1.15, 0 of 3 at 1.0),
so the full task ran 4 times at each value with every tool call executed: all
8 runs passed, 1.15 made no syntax-breaking edits and no invalid tool calls,
and 1.0 made 2 and 1. The publisher's model card calls 1.15 "Critical for
agents. Without it, greedy decoding loops on repeated tool calls", and
recommends temperature 0.1 to 0.3 for agents, which covers Qwen Code's 0.2.
Ollama's OpenAI endpoint has no per-request `repeat_penalty` anyway, and the
tag is also the retired failover model. The fresh-session retry in `qwen goal` is
what absorbs these slips.

Four settings let that loop continue within the configured window:

| Setting | Why |
|---|---|
| No `model.maxToolCallsPerTurn` | Any explicit value is a hard cap. The old `12` halted every turn at call 12; the default halts only on repeated calls, with a backstop at 1,000. |
| No `model.skipLoopDetection` | `false` enabled the streaming heuristics that halted the run after compaction. Qwen Code's always-on guard against identical repeated calls stays. |
| `context.clearContextOnIdle.toolResultsTotalCharsThreshold: 24000`, `toolResultsNumToKeep: 3` | Replaces old tool output with a placeholder and keeps the calls, so the model still knows what it ran. The default of 500,000 chars retains much more tool output. A request shows four file pages at most. The progress hook's `RESULTS_KEPT` must equal `toolResultsNumToKeep`, and a test fails if they drift. |
| `model.chatCompression.maxRecentFilesToRetain: 1`, `tools.truncateToolOutputThreshold: 8000`, `truncateToolOutputLines: 200` | Summary compaction used to re-attach up to five files at 5K tokens each, which put a session straight back over the trigger. |

Measured on a fixture with six planted bugs and about 8K tokens of source,
27B headless: the run fixed every test in 16 tool calls and 7 minutes. The
prompt peaked at 21.9K tokens, tool-result clearing took it from 18.9K to
15.7K once, and neither summary compaction nor a loop halt fired.

Main coding requests now also send `reasoning_effort: none` through the OpenAI
API, including requests after tool results. This follows the modified 27B model
publisher's recommended non-thinking mode; the previous main-provider config
left thinking enabled. The installed-client regression test checks the actual
request body and retained tool result against a local API fixture. It does not
prove that 27B completes a real build without repetition: that comparison remains
pending sufficient physical memory. Start a new Qwen session to load this setting.
The model tag, weights, Ollama template, and memory admission guard are unchanged.

The Goal verifier needs a second model. Qwen Code aborts it after a fixed
30 seconds, in 0.24.0 too, and the 27B reads prompts at about 268 tokens per
second, so an 11K-token verifier prompt timed out every time. The config sends
side queries to `QWEN_FAST_MODEL` (default `qwen3.5:4b-256k`) with
`reasoning_effort: none`: the 4B answered a verifier-shaped request in 1.0 s
against 9.5 s with thinking on, and Ollama ignores the `enable_thinking: false`
that Qwen Code sends. In a test run the 4B verifier rejected a completion claim
that cited the wrong evidence, and the 27B went back to work.

Ollama will not hold both models on this Mac, so each verification unloads the
27B, runs the 4B, and reloads the 27B. Verification runs only when the model
claims it is done, so the config turns off the side queries that would swap
every turn (`experimental.emitToolUseSummaries`,
`ui.enableFollowupSuggestions`) and the launcher sets `QWEN_DISABLE_AUTO_TITLE=1`.
A 4B that is not pulled falls back to the session model. When the session
model is also the side-query model (plain `qwen`, or that fallback), the launcher
writes a copy of the config with one provider to
`~/.cache/qwen/qwen-code-local.single-model.json`, because two entries with the
same id could hand the session the side-query entry's `reasoning_effort: none`.

An agent session that attaches to an already-loaded model now takes the
compute lock and lease when they are free. During a test run the verifier swap
left no 27B loaded and no lock held, and another local job loaded its
own model into the gap. A Qwen Code session releases its lease the moment it
exits, because the launcher waits for Qwen Code instead of `exec`-ing it. `qwen
raw` still `exec`s `ollama run`, so its lease stays until the next launch prunes it.

With the 27B loaded and the usual desktop apps open, this Mac ran at 14% to 18%
free memory. Claude Code's memory guard for its own background tasks killed two
of four test runs at that level, so start long Goal runs from a terminal.

The 27B selector owns the shared local-compute lock. If a cooperating LLM-Jury
council holds that lock, the launcher terminates that exact
holder, waits for the kernel lock to release, and then runs the normal pressure
and RAM checks. It refuses to force-stop another Qwen or Ollama process. A 4B
launch keeps the non-preemptive behavior. When Qwen owns the 27B lease,
`llmjury solve --backend ollama --frontier auto` skips the local council and
uses the remote verifier-gated ladder, so the two workloads never share model
memory. An in-flight council loses its current turn when Qwen preempts it; a
new invocation performs the frontier handoff.

The launcher also reclaims an abandoned Qwen session when the lock holder is a
Qwen process older than 30 minutes and Ollama reports no resident model. Set
`QWEN_STALE_SESSION_SECONDS` to tune that threshold. A reclaim also stops the
processes the session spawned: Qwen Code's launcher does not pass TERM on to its
CLI, which kept running after its parent died. The launcher reads the
session's age from `ps -o etime`. It used the lease file's mtime until the
lease prune started deleting leases past their 4-hour expiry while the session
still ran, which left every session older than 4 hours unreclaimable. The launcher keeps a live
Qwen session or any Ollama owner protected when it cannot prove that the session
is stale.

For better throughput, use `qwen` for broad repository discovery and `qwen 27b code`
for a focused implementation slice. Give the 27B a named phase or target, ask it to
edit and test that slice, and keep further inventory out of the turn unless the edit
needs it. Keep other local models stopped while the 27B is resident.

The provider label Qwen Code prints in its banner and footer is the model tag
itself, such as `qwen3.5:4b-64k (Ollama)`, expanded from `QWEN_SESSION_MODEL`
at startup. It used to read `Qwen local (Ollama)`, which said nothing about
which weights were loaded, and asking the model does not help: Qwen Code's
system prompt tells it it is Qwen Code, so it denies being the obliterated
build even when `ollama ps` and the process arguments show that it is. Read
the footer, or `ollama ps`, never the model's own answer.

Qwen Code reads `AGENTS.md` and `QWEN.md` for project instructions and uses its own
`~/.qwen` settings, skills, MCP servers, approvals and session history. The
Claude-specific hooks and memory integration below apply only to `qwen claude`.
Normal approval prompts remain enabled. Use Qwen Code's native MCP commands to
add integrations; `--mcp cmem` and `--tools lean` are alternate-client options.
File, shell, search, skill and fetch tools load at startup. Qwen Code can discover
other registered tools through `tool_search`, keeping their schemas out of the
initial context without removing their capabilities.

Run `bash scripts/test-qwen.sh` to check routing and admission without loading a
model. Verify real tool execution with a small disposable project before relying
on a model for larger builds; a textual claim alone does not prove an edit or build.

---

## A `qwen claude` session says Qwen, not Haiku

Claude Code refuses any model id outside its compiled catalog, so the selected local
model is served under one: `claude-haiku-4-5-20251001`, an `ollama cp` manifest copy
that shares its blobs and runner with whichever Qwen tag the launcher selected. Every
surface that derives a name from the id then calls the session Haiku 4.5, which is the
one thing on screen that is false.

Two places now say otherwise:

- **The status line.** `qwen claude` exports `QWEN_SESSION_MODEL`, and
  `scripts/statusline.sh` prints `QWEN LOCAL` in place of the payload's display name.
  It reads the variable from its own environment, or off the parent `claude` process,
  the same walk the failover badge uses. A session pointed at port 11434 with no
  wrapper to label it still reads as local.
- **`/model`.** The picker builds its labels from
  `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL_NAME` when they are set, so all
  four now read the selected Qwen tag, such as `qwen3.5:4b-64k (local)`. Override
  with `QWEN_MODEL_LABEL`.

The fable slot joined the other three in pointing at the alias. A slot left on a real
Claude id is a 404 against Ollama the moment anything selects it, and a second local tag
would load a second runner, which is the co-residency that panics this Mac.

Claude Code has no environment variable for the session's own display name — `Ise`, the
override map behind it, is a static table of marketing names — so the status line is
where this gets fixed rather than in a flag.

---

## claude-mem inside a `qwen claude` session

Recall works the way it always did: `--mcp cmem` wires the hosted cmem MCP, and the
plugin's hooks inject context at session start.

Capture needed a fix, and the bug it prevents is machine-wide. claude-mem runs **one**
worker daemon per machine, and its observer compresses a session by spawning the
`claude` CLI with the daemon's own environment. Nothing in claude-mem strips
`ANTHROPIC_BASE_URL` along the way. So when a `qwen claude` session is the one whose
SessionStart hook first starts that daemon, the daemon inherits the local base URL and
auth token, and from then on every memory compression on this machine — cloud sessions
included — is answered by Ollama until somebody notices.

`scripts/qwen` now starts the worker itself, before the exec that sets those variables,
with `env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL`. claude-mem's
hook then finds a healthy worker on `127.0.0.1:37700 + uid % 100` and does nothing. If
claude-mem is not installed, or `node` is missing, the wrapper skips it. Memory is not a
reason to refuse a session.

A worker that is **already** running gets checked rather than restarted: if its
environment points at Ollama, the wrapper says so and leaves it alone. Killing that
daemon drops the backoff that keeps it off a rate-limited provider, and that is Shawn's
call to make.

`QWEN_MEMORY=0` turns the whole thing off — no recall server, no worker, nothing
started on claude-mem's behalf. An explicit `--mcp` still wins over it.

---

## `qwen` agent sessions know what tools they have

`qwen claude` and `qwen codex` now default to `--tools lean`, and append
`prompts/qwen-tools.md` to the session's system prompt.

Both halves were missing, and together they produced a specific failure: the model
would answer *"Pulling the latest HyperCrawl from the repo now"* and then nothing
happened. The old default, `--tools mcp`, disallowed `Bash Read Write Edit Glob Grep`
— so it had no way to pull anything — and nothing in its context said the tools it did
have were real rather than a description of what someone else would do. A local model
with no briefing narrates the action instead of taking it, and that reads exactly like
work being done.

`lean` keeps `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `TodoWrite` and `WebFetch`,
dropping only `WebSearch`, `Task` and `NotebookEdit`.

**`WebSearch` is excluded on purpose, not by oversight.** It is an Anthropic *server-side*
tool, and these sessions talk to Ollama — offering it would hand the model a tool that can
only ever error. `WebFetch` is client-side (Claude Code retrieves the page, the local model
reads it), so it works and is enabled.

For anything on GitHub the model uses `Bash`: `gh` is installed and already authenticated,
so `gh repo clone` and `gh api` work with no credential prompt. The brief says so explicitly,
because "pull the latest X and evaluate it" is a task the model can actually complete —
clone it, then read what you cloned — and the failure being fixed here was describing that
instead of doing it. The brief costs about **428
tokens against the model's 256K window** — cheap against one confidently invented answer.

It states two rules plainly: never claim an action without calling a tool, and read the
file rather than answering from memory about a specific codebase. Then a short table of
which tool suits which question, and an explicit list of what the model does *not* have,
because "I cannot reach that" is a useful answer and a confident guess is not.

Override per session with `--tools mcp` (the old lean-window behaviour) or `--tools all`.
The brief is skipped under `--tools mcp`, where most of what it describes is unavailable.

---

## Claude status line

`scripts/statusline.sh` is the canonical source for Claude's optional status line. It prints the
session model, the working directory, and the shell and legion worker counts. A model served
locally shows as `QWEN LOCAL`; every other model shows its own name.

Installing is a separate step from merging, so compare the hashes before you trust what
you see on screen:

```bash
md5 -q scripts/statusline.sh ~/.claude/statusline.sh   # two lines, same value
cp scripts/statusline.sh ~/.claude/statusline.sh
```

### The local-model badge

`qwen claude` exports `QWEN_SESSION_MODEL`, and the status line prints `QWEN LOCAL`
instead of the model name in the payload. Without it the line reads "Haiku 4.5" for a
session Anthropic never sees: the local weights are served under a borrowed catalog id,
and Claude Code derives every name it prints from that id.

The variable is read from the status line's own environment first, then off the parent
`claude` process, which is the walk the failover badge already does. A session whose
`ANTHROPIC_BASE_URL` points at port 11434 with no wrapper to label it reads as
`LOCAL · ollama`, and any other local tag is named: `LOCAL · gemma3:12b`.

### The local-tier badge

When the router fails a session over to local weights, the status line shows
`LOCAL TIER . Anthropic down` in place of the model name.

It replaces the name rather than sitting beside it, because during a failover the name is the one
thing on the line that is false: Claude Code still believes it is talking to its configured cloud
model and has no idea the router answered from Ollama. Showing both would print the lie and the
correction side by side.

This badge exists because the router's notification cannot cover the whole problem. The router
already notifies on both transitions — into local and back to cloud — but those notices are rate
limited by `failover_notify_cooldown_seconds` (900s). A second outage inside that window moves the
session to local and back with **no notification at all**, which is the silent switch people
actually hit. Notifications report events; this reports state, and state is the half a cooldown
cannot suppress.

Three independent conditions are required, each closing a different way to lie:

| Condition | What it prevents |
|---|---|
| This session is routed through the router (the configured local endpoint, read from the env or walked up the process ancestry) | Breaker state is global to the router, so a session talking directly to Anthropic must not inherit a badge from one that is routed |
| `failover_active` is true **for `anthropic`** in the retired failover state file | A Codex failover says nothing about a Claude session |
| The file's `pid` is alive **and is really the router** | A state file outlives the process that wrote it, and a recycled pid would otherwise resurrect a badge for a router that is gone |

Anything invalid, unreadable, or unverifiable fails closed and renders no badge. A stale proxy
variable left over from a retired router still changes nothing, because the environment alone was
never sufficient.

There is deliberately **no "off" badge.** The old failover OFF badge printed on every ordinary
session and told nobody anything; the normal case does not need a label.

`jq` is a hard dependency, and a missing one used to be invisible. The script parses the session
payload with `jq`, so a host without it printed a bare ` . shells: 0` and exited 0: no model name
and no way to tell that was a failure. The script now checks for `jq` first and prints
`STATUSLINE BLIND . jq not found on PATH . no model or local-tier badge` instead of a
comfortable blank.

Run the fixture gate with:

```bash
scripts/test-statusline.sh
```

Six checks run: the cloud model name, three stale routing environments that must not revive a
badge, the local-model label, and the missing-`jq` announcement.

Repository changes do not install the script into `~/.claude`. Installation needs a separate
decision, a backup of the current script, a passing fixture run, `bash -n`, and an atomic rename.

## Installation

```bash
# 1. Clone this repo
git clone https://github.com/Screddyice/claude-code-harness.git
cd claude-code-harness

# Check the repository and installed Claude plugin boundary.
scripts/audit-claude-harness.sh --installed
scripts/verify.sh
scripts/test-audit-claude-harness.sh   # the audit uses grep, so it works without ripgrep

# Run the local Claude plugin tests before making an installation change.
scripts/test-statusline.sh

# Optional: replace Claude Code's deadline-bound native updater on slow links.
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

## Client boundary

Claude hooks and shared utilities stay in this repository. Codex configuration, Codex
hooks, and Codex plugin marketplaces live in [`codex-harness`](https://github.com/Screddyice/codex-harness).
Use that repository when a task needs a Codex plugin or Codex-specific installation.

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

## Kernel Zone Leak Watchdog

macOS can run out of *kernel* memory while every app looks fine. On 2026-09-04 this
Mac panicked after 35 hours of uptime:

```
panic(cpu 15): zalloc[3]: zone map exhausted while allocating from zone
[data.kalloc.1024], likely due to memory leak in zone [data.kalloc.1024]
(20G, 21218528 elements allocated)
```

Twenty gigabytes of one-kilobyte kernel allocations, none of them freed. Two
`JetsamEvent` reports earlier the same day already showed the shape of it: 23.5 GB
wired against only 4.3 GB of anonymous application memory. Activity Monitor shows
this as "wired" and attributes it to nothing, because no process owns it — which is
why it reads as "the machine got slow and then died" rather than as a leak.

The panic log does not say which subsystem leaked. Zone allocation backtraces need
the `zlog=<zone>` boot-arg, set before the fact. So this watchdog samples the zone
table on an interval instead, and captures the evidence at the moment a zone crosses
a threshold — turning the next occurrence into an attribution instead of another panic.

```bash
scripts/kernel-zone-watchdog.sh            # one sample; exit 0 quiet / 1 warn / 2 critical
scripts/kernel-zone-watchdog.sh --status   # ten largest kernel zones right now
scripts/kernel-zone-watchdog.sh --report   # sample count, latest reading, growth per hour
scripts/kernel-zone-watchdog.sh --watch    # sample forever, for a foreground session
```

`--status` on a healthy machine puts the largest zone in the low hundreds of megabytes:

```
ZONE                                     ELEM        INUSE         SIZE
APFS_4K_OBJS                             4096        43601     170.3 MB
APFS_INODES                               432       262396     108.1 MB
vm.pages.array                             48      2273042     104.1 MB
```

**Thresholds are set far apart on purpose.** Idle `data.kalloc.1024` on this machine
sits near 1,500 elements — about 2 MB. Warning fires at 1 GiB and critical at 6 GiB,
both orders of magnitude above noise and hours ahead of the 20 GB that killed it.
Override with `KERNEL_ZONE_WARN_BYTES` / `KERNEL_ZONE_CRIT_BYTES`.

Crossing a threshold writes a snapshot under
`~/.local/state/kernel-zone-watchdog/snapshots/` holding the full zone table, `vm_stat`,
`netstat -m`, a process-name histogram, `launchctl list`, and processes ranked three
ways — by RSS, by cumulative CPU time, and by age. A 30-minute cooldown keeps a
sustained leak from filling the disk with snapshots.

**Ranking by RSS alone is not enough, and the 2026-09-04 panic is why.** The two
processes that stood out in that panic report held *0.1 MB resident* while burning 4.5
hours of kernel CPU and 4.15 billion page faults each — 64× the page faults of any other
process on the machine. An RSS-sorted list puts them nowhere near the top and shows you
a browser instead. Cumulative CPU time is what surfaces them.

Install it as a LaunchAgent that samples every minute:

```bash
cp examples/com.screddy.kernel-zone-watchdog.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.screddy.kernel-zone-watchdog.plist
```

Samples append to `~/.local/state/kernel-zone-watchdog/samples.csv` as
`epoch,iso,zone,elem_size,inuse,zone_bytes,wired_bytes`, so a leak's growth rate is a
one-line `awk` away after the fact. Run `scripts/test-kernel-zone-watchdog.sh` to
verify parsing, both thresholds, snapshot contents, and the cooldown; it touches only
a temp directory.

## Optional hooks

No hook in this repository installs itself. The machine-global PR tracker, the PR enforcer and
the Ollama diff reviewer were removed on 2026-10-09 after their registrations were retired; PR
tracking is the explicit `scripts/track-branch-pr.sh` command above. What remains is opt-in:

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

## Workspace root (multi-org)

When this harness is installed on a multi-org machine (e.g. Shawn's `~/projects`), hooks and
skills are **user-global**. Opening Claude Code from the workspace root or
from any org/repo under it uses the same harness. Workspace docs: `~/projects/CLAUDE.md`,
`~/projects/AGENTS.md`. Org folders only add thin pointers; git `origin` selects company
credentials.

| Harness | Workspace entry points |
|---------|------------------------|
| Claude Code | `~/projects/CLAUDE.md`, `~/projects/.claude/skills` → `~/.claude/skills` |

## Selecting local Qwen models (`scripts/qwen`)

Type `qwen` for Qwen3.5 4B, or `qwen 27b` for Qwen3.8 27B OBLITERATED. `Qwen` and `QWEN` reach the
same file, because the boot volume is case-insensitive APFS.

```
qwen                        standalone Qwen Code agent on 4B
qwen 27b                    standalone agent on the obliterated 27B
qwen 27b raw "hello"        plain chat on the obliterated 27B
qwen "explain this diff"    one-shot agent task
git diff | qwen             prompt from stdin
qwen status                 what is resident, who owns compute
qwen stop                   unload now instead of waiting out keep_alive
qwen claude                 Claude Code on this model, tools that run
qwen codex                  Codex on this model
```

Install it the way `gbrowse` installs:

```bash
ln -sfn "$PWD/scripts/qwen" ~/.local/bin/qwen
```

Claude's catalog alias must have the same Ollama manifest digest as the selected
model. The launcher refreshes an idle stale alias, and refuses to repoint one
that is still resident. Status and stop commands count the alias only when its
digest matches, so `qwen stop` cannot unload a 27B alias selected by another
session. Use `qwen 27b stop` to stop that model.

### Why a wrapper instead of `ollama run`

the retired failover service was removed on 2026-09-10 and took `~/.local/bin/qwen` with it. What the
wrapper did before the load matters more than the wrapper. This tag puts 16.3 GB of
wired Metal memory on a 36 GB Mac, and wired pages cannot swap out. Put an llm-jury
council or a background diff review beside it and the host compresses everything
else until the kernel watchdog starves and panics, which it did twice on
2026-07-31. Nothing sees a catchable out-of-memory error, so every guard here runs
before the first byte loads.

LLM-Jury's memguard already names this model: `EXCLUSIVE_MODELS` is exactly
`{"qwen3.8:27b-obliterated"}`. Cooperating local jobs stand down while it owns
compute, and they learn that two ways, from a lease file under
`~/.cache/llmjury/compute-leases` or from the model appearing in Ollama's `/api/ps`.
`scripts/qwen` publishes the lease, because Ollama needs tens of seconds to load
this model and a competing job starts in far less. It also holds
`~/.cache/llmjury/local-compute.lock`, the same nonblocking lock the council
takes, so the two never race.

The shared lease path is retained for compatibility. memguard's other readers
resolve that default path, and renaming it here would quietly stop gating them.
Move both sides together with `LLMJURY_COMPUTE_LEASE_DIR`.

### Smaller local jury council

For a 36 GiB Mac, `scripts/install-local-council.py` installs host-local jury
defaults: Qwen3.5 4B + Phi-4 Mini 3.8B, 8192 context, and verifier-gated
authenticated Codex fallback. It wraps the `llmjury` and `jury` symlinks while
keeping their pipx executables. Only local Ollama `solve` calls receive these
defaults; explicit models, context, frontier and memory-check options still work.

```bash
python3 scripts/install-local-council.py
python3 scripts/test-local-council.py
```

The model files total about 5.5 GiB, compared with 12.2 GiB for Gemma 12B + Llama
8B. Runtime memory also includes KV and prompt caches. This installer changes
no memory policy or service configuration; macOS and Ollama retain their existing
controls. Smaller models may need Codex fallback more often.

Frontier escalation goes through the authenticated Codex CLI (`--frontier-backend codex`), never
OpenRouter, which this machine reserves for JEV. The wrapper also keeps LLM-Jury's router state and
compute leases under `~/.cache/llmjury/`. `scripts/local-council.py` is the source for the installed
`~/.local/bin/local-council`; change it here, then rerun the installer.

Original executable paths live in `~/.config/llmjury/local-council.json`. To undo
the defaults, restore each `llmjury`/`jury` symlink to its saved path.
The installer serializes updates and replaces staged files atomically, keeping
working aliases usable after a failed write. It rejects unrelated wrapper files
and invalid saved executable paths before replacing anything.

### Local-model memory ownership

macOS owns system memory pressure and Ollama owns model residency. The launcher checks
the native pressure level before starting a session, unloads other models unless
`--keep-others` is set, and holds the shared compute lock so cooperating local
clients do not load models at the same time. It does not maintain a second byte
budget or reject a model because its tag advertises a larger context window.

`--force` remains accepted for script compatibility, but it does not bypass an
elevated macOS pressure level. Use Ollama's own settings and `ollama ps` to inspect
model residency. LLM-Jury's custom preflight is opt-in with `--mem-check refuse`;
its normal macOS path leaves RAM admission to macOS and Ollama.

### Agent sessions: `qwen claude` and `qwen codex`

Both run a full agent session against the local model, with the same guard, lease
and lock as everything else here. There is no failover in either direction. You
asked for the local model, so you get the local model until you quit; retired router
swapped tiers under a live session, which is what made it unreliable enough to
delete.

```
qwen claude                    Claude Code on the default 4B, cmem wired in
qwen 27b claude                Claude Code on the obliterated 27B, cmem wired in
qwen agent                     standalone Qwen Code (see above)
qwen codex                     Codex on the default 4B, cmem wired in
qwen 27b codex                 Codex on the obliterated 27B, cmem wired in
  --mcp cmem|none|all          MCP servers (default: cmem)
  --tools mcp|lean|all         built-in tools alongside MCP (default: lean)
  QWEN_MEMORY=0                no recall server and no claude-mem worker
  QWEN_MODEL_LABEL=...         what `/model` calls this model
```

Ollama 0.32 serves the Anthropic Messages API at `/v1/messages`: correct envelope,
`tool_use` blocks, thinking blocks, SSE streaming, and it ignores the auth headers.
Codex goes over Ollama's OpenAI-compatible `/v1/responses` endpoint. The wrapper
sets `model_providers.qwen.wire_api=responses`, which current Codex requires. Neither
client needs the translation proxy the old setup provided, so nothing gets rebuilt.

#### Optional JEV decisions for local sessions

With `jev-mcp` installed and its OpenRouter credential available, the guarded
launcher attaches JEV to Qwen Code, goals, Codex and Claude sessions. The local
model uses it for classification, evidence checks, scoring, ranking and record
matching without an `@JEV` tag. The launcher puts the routing guidance into the
session prompt, including probability thresholds, data restrictions and request
limits. Qwen Code gets the JEV schema upfront and concrete JSON examples to
avoid tool-name and nesting errors on smaller models. Coding and chat inference
stay on Ollama.

A public OpenRouter HEAD probe has a two-second total timeout and no retries.
If it fails, or the launcher or credential is missing, the session skips JEV and
uses local judgments. If connectivity drops after startup, the prompt tells the
model to disclose its local fallback and avoid retrying an uncertain billed call.
`QWEN_JEV=0`, `QWEN_OFFLINE=1` and `--mcp none` skip the probe and JEV attachment.
These switches do not change the existing memory-worker controls.

The MCP entry contains a launcher path. It never contains a key value. The
launcher reads `JEV_OPENROUTER_API_KEY` from its environment or its protected
runtime file. Existing OpenAI accounts and the local admission, lease and lock
checks still apply. `qwen raw` has no tools and uses local judgments.

Qwen Code keeps its existing MCP selection by default; `--mcp cmem` restricts it
to memory and available JEV, and `--mcp none` excludes MCP servers. Codex and
Claude keep their `cmem` default, with online JEV added. In `--mcp all`, offline
Codex disables inherited JEV and Claude blocks its tool calls. Codex table
overrides merge with saved settings, so the launcher disables excluded saved
servers by name for its `cmem` and `none` selections. Generated Qwen
settings contain no secrets and the launcher removes them on exit.

Run `bash scripts/test-qwen.sh` for online/offline attachment, opt-outs,
credential-free arguments and the existing model admission checks. The suite
uses fake services and does not load a model or call OpenRouter.

#### The model id is the catch

Claude Code 2.1.267 validates the session model against its own compiled catalog
and answers `[claude-code:unrecognized_model]` for anything else, wherever
`ANTHROPIC_BASE_URL` points. Measured on this host, in order:

| Attempt | Result |
|---------|--------|
| `ANTHROPIC_MODEL=qwen3.8:27b-obliterated` | refused |
| a claude-shaped tag, `claude-qwen-27b` | refused |
| plus `ANTHROPIC_CUSTOM_MODEL_OPTION` | refused |
| plus `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` | refused |
| the same blobs under a catalog id | worked first try |

So `qwen claude` runs `ollama cp <selected-model> claude-haiku-4-5-20251001` when the
alias is missing or stale and idle. That copies the manifest, not the weights: the
measured delta on this host was 0 KB for the 27B alias, and Ollama keeps one runner for
matching tags. Override the id with `QWEN_CLAUDE_MODEL_ID`.

Every model slot — `ANTHROPIC_MODEL`, the Opus, Sonnet and Haiku defaults,
`ANTHROPIC_SMALL_FAST_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL` — points at that one
alias. Claude Code resolves its background work separately from the main model, and
both other outcomes are wrong: a real Claude id 404s against Ollama, and a second
local tag loads a second runner, which is the co-residency that panics this Mac.
Codex needs none of this; it has no allowlist and takes the real tag.

The wrapper treats the alias and the selected canonical tag as one model only when their
manifest digests match. It refreshes an idle stale alias, refuses to repoint one that is
still resident, and keeps status and stop scoped to the matching alias. Reporting the
matching alias as "not loaded" is how you end up holding memory you believe is free;
unloading a stale resident alias is how you evict another session.

#### Keeping the context usable

Tool schemas are the largest thing competing with your actual work for this window,
so both defaults are narrow:

- `--mcp cmem` loads claude-mem's hosted recall and nothing else. `--mcp all` loads
  every server in `~/.claude.json` (14 of them) or `~/.codex/config.toml` (13), which
  will crowd the window. `--mcp none` loads nothing.
- `--tools mcp` drops the built-in tool surface and leaves MCP as the tool layer.
  `--tools lean` keeps file and shell tools and drops the web and subagent ones.
  `--tools all` restricts nothing.

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is pinned to the model's own context, and
`CLAUDE_CODE_NO_MODEL_FALLBACK=1` stops Claude Code substituting another model.

#### claude-mem

The capture and injection hooks in `~/.claude/settings.json` fire in a local session
like any other, so the session is recorded and past context is injected without any
extra wiring. Recall is the `cmem` MCP server, which both agent commands add by
default.

Neither command copies the token. Claude Code expands `${VAR}` inside
`--mcp-config` (verified on this host), so the generated config carries
`Bearer ${CMEM_PRO_TOKEN}` and never a value; Codex takes `bearer_token_env_var`
and looks the variable up itself. `CMEM_PRO_TOKEN` comes from the environment, or
from `~/projects/.env` when it is not exported. `ANTHROPIC_API_KEY` is dropped
rather than forwarded, since a local server has no use for the real key.

Codex settings are all `-c` overrides, so `~/.codex/config.toml` is never edited and
a session that dies leaves nothing pointing at a local model.

Run `scripts/test-qwen.sh` after changing admission, locking, lease handling, or
the agent commands. Its checks stub Ollama, launchd, both memory probes and
both agent binaries, so no case loads a model or starts a session.

## MCP And Apps

### Document and presentation authoring

Claude's Gstack installation provides `document-generate`, `document-release`, and
`make-pdf`. For DOCX, XLSX, PPTX, PDF, and data-backed templates, install the official
`carbone-skill` plugin as described in [`docs/authoring-tools.md`](docs/authoring-tools.md).

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

## Hermes plugins (`hermes/`)

`hermes/plugins/cmem` is the claude-mem memory provider deployed to `~/.hermes/plugins/cmem/`
on all three Hermes boxes. It was hand-deployed and lived nowhere else; a rebuilt box now has a
source to copy from. One memory project per box, and no writes until something is actually
remembered. Details and the deploy command: `hermes/README.md`.

## Memory capture gate (claude-mem)

`scripts/hooks/memory-capture-gate.sh` runs on SessionStart and keeps client repositories out of
agent memory. It reads the git **origin remote**, and for `teamnebula-ai` or `Reddy2help` writes
`.claude/settings.local.json` with `enabledPlugins["claude-mem@thedotmack"] = false`, which beats
the user-level `true` by settings precedence. It replaces the identical gate that guarded the
Cognee plugin until 2026-09-04; only the plugin id changed.

Two things it deliberately does not do. It does not use `CLAUDE_MEM_EXCLUDED_PROJECTS`, which
matches on folder name, because a client repo cloned under any other name would capture. And it
cannot affect the session that writes the file: plugin enablement resolves at startup, so the
first session in a freshly cloned client repo still captures and every later one does not; the
systemMessage says so.

## The capture gate does not depend on this checkout

The gate is registered as a `SessionStart` hook at the fixed path
`~/.claude/scripts/memory-capture-gate.sh`. That file is `scripts/hooks/memory-capture-gate-wrapper.sh`,
and it runs the implementation installed beside it at `~/.claude/scripts/memory-capture-gate.impl.sh`,
a copy of `scripts/hooks/memory-capture-gate.sh`. It prints a loud `systemMessage` when the
implementation is missing.

It used to `exec` this repo's copy. This repo is a working tree that moves between branches, and
for weeks before 2026-09-04 the checkout sat on a branch without the script, so the gate never ran
and TMN sessions were captured. A gate that fails open looks the same as a gate with nothing to
do. After changing the gate here, copy both files into `~/.claude/scripts/`.

The excluded orgs are `teamnebula-ai`, `Reddy2help` and `BH-Repos`. RS21 needs no entry: those
repos live under `teamnebula-ai`.

## Publishing environment into the macOS GUI domain (`scripts/set-gui-env.sh`)

A Dock-launched app inherits launchd's environment, not a shell's. Nothing in `~/.zshrc` and
nothing in `~/projects/.env` reaches Codex Desktop, so its `cmem` MCP server — which declares
`bearer_token_env_var = "CMEM_PRO_TOKEN"` — starts with no bearer and its tools simply never
appear. That failure reads as a missing feature rather than a missing credential, which is why it
went unnoticed.

`launchctl setenv` fixes it for the session and is lost at logout. This script reads the named
keys out of `~/projects/.env` and publishes them, and
`examples/com.screddy.gui-env.plist` runs it at every login so a reboot cannot quietly
un-configure the app.

```bash
cp examples/com.screddy.gui-env.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.screddy.gui-env.plist
launchctl getenv CMEM_PRO_TOKEN >/dev/null && echo published
```

`GUI_ENV_KEYS` selects which keys to publish (default `CMEM_PRO_TOKEN`) and `GUI_ENV_SOURCE` the
file to read. A one-line `~/projects/.env` pointer is followed when the generated file is present.
For `NEBOS_OS_BEARER_TOKEN`, the publisher also uses the existing authenticated SRCOS header in
`~/.claude.json` when the env source is unavailable. Secret values are never written into the
plist or log; the log records only the key name and a character count. A missing file or key exits
0 with a message rather than failing login.

The script also publishes derived, non-secret values. It reads `LLMJURY_OLLAMA_PARALLEL` from
`OLLAMA_NUM_PARALLEL` in Ollama's own launchd unit (`OLLAMA_PLIST` overrides the path). Ollama
exports that setting to its server process and nowhere else, and llm-jury's memguard charges KV as
`num_ctx x` this number, falling back to Ollama's default of 4 when it cannot see the real one. A
GUI-launched session running the council therefore overestimates and refuses
work without it. An absent, malformed, or zero value unsets the variable instead of publishing a
wrong one: memguard's conservative default is the safe direction, a bad number is not. The secret
loop and this block are independent, so a missing env file no longer skips the derived value.

It reads `LLMJURY_PROMPT_CACHE_MIB` from `LLAMA_ARG_CACHE_RAM` in the running Ollama
launchd job. This keeps GUI-launched jury consumers from reserving the default 8 GiB when
the server uses a smaller cache. The publisher checks the active job because an edited plist
does not change the server's limit until a restart. An unavailable job or a missing, invalid,
or unlimited bound removes the override and leaves memguard's conservative default in place.
`OLLAMA_LAUNCHD_TARGET` can select another job for a read-only probe. A missing secrets file
does not skip either derived setting. Existing apps inherit the new values on their next launch.

This moved here on 2026-09-10 from `router-gui-env.sh`, which was deleted with the retired local service
router. That script also health-gated `ANTHROPIC_BASE_URL` onto the router and published a Mem0
key; both are retired, so neither came across. The example plist gained `StartInterval 3600` to
replace its 60-second poll.

The Hermes boxes deliberately do not use this. Each keeps its own mode-600 `~/.hermes/cmem.env`
and the provider reads the environment then that file, so there is no launchd or GUI session to
lose. Verified on `src`, `reddy2help` and `neb-ops-gcp` with `CMEM_PRO_TOKEN` explicitly unset.

Tests: `scripts/test-set-gui-env.sh` (21 assertions, stubs `launchctl` so it never touches the
real domain and a fixture plist so the derived value never depends on this host's Ollama setup,
and asserts the secret value is never printed). The cache tests distinguish the active job
from its saved plist and cover missing, malformed, unlimited, and unavailable limits.

## MCP auth headers without a stored value (`scripts/mcp-headers.py`)

Claude Code runs an http MCP server's `headersHelper` command at connect time and sends the JSON
object it prints as request headers. This helper prints one header whose value it reads from the
process environment, then the GUI launchd domain, then `~/projects/.env`
(`MCP_HEADERS_ENV_FILE` overrides the path). The MCP config names a variable and never holds the
secret, and the lookup works in a Dock-launched session that `set-gui-env.sh` never covered.

```bash
install -m 755 scripts/mcp-headers.py ~/.claude/scripts/mcp-headers.py
claude mcp add-json --scope user cmem \
  '{"type":"http","url":"https://cmem.ai/api/mcp","headersHelper":"/Users/screddy/.claude/scripts/mcp-headers.py Authorization CMEM_PRO_TOKEN Bearer"}'
claude mcp get cmem        # Status: ✔ Connected
```

Arguments are `HEADER VAR [SCHEME]`. A missing variable exits 1 and names the variable, so Claude
Code reports the server as needing authentication instead of connecting without credentials.

Since 2026-09-26 the Team Nebula config (`~/TeamNebula/team-context/.claude.json`, the file a
session reads when `CLAUDE_CONFIG_DIR` points there) uses it for `cmem` (`CMEM_PRO_TOKEN`),
`srcos` (`NEBOS_OS_BEARER_TOKEN`) and both Composio servers (`TMN_COMPOSIO_API_KEY`, which
`set-gui-env.sh` does not publish). `~/.claude.json` still carries those values inline.

Tests: `scripts/test-mcp-headers.sh` (9 assertions; stubs `launchctl` and uses a fixture env
file, and checks that the value never reaches stderr).

## Creating agent worktrees safely (`scripts/agent-worktree.sh`)

On 2026-09-05 an agent ran this shape against a branch that was already checked out
somewhere else:

    git worktree add -q "$W" -B "$branch" "origin/$branch" || true
    cd "$W"
    git merge origin/main

`worktree add` refused, `|| true` swallowed the refusal, `cd` failed, and the shell stayed where it
was — the user's **main checkout**. The merge ran there. It was clean and on the intended branch so
nothing was lost, but the next such slip lands a write in whatever repo the shell was last in.

Two things made that possible, and the script fixes both. A create that fails is never ignored: a
branch checked out elsewhere is reported by name with the path that holds it, and the script exits
3 rather than guessing. And the command runs in a subshell whose `cd` is checked, so a failure
cannot fall through to the caller's directory.

    scripts/agent-worktree.sh <repo> <branch> <start-point> [--] <command...>

With no command it creates the worktree, prints the path and leaves it. With one it runs the
command inside and removes the worktree afterwards. Tests: `scripts/test-agent-worktree.sh`. The
first test reproduces the incident, and the suite was run against the original broken pattern to
confirm it fails there (4 of 5, including the command executing in the caller's directory).

## Auditing instructions for retired components (`scripts/audit-stale-instructions.sh`)

Instruction files are read by every agent on every session and are never executed, so a component
can be deleted from the machine while every agent is still told it is canonical. Nothing fails; the
agents simply act on a world that no longer exists.

That happened on 2026-09-04. Cognee was removed from the whole fleet, and afterwards
`~/.codex/AGENTS.md` still opened with "Memory = Cognee", naming a plugin that no longer existed
and a port with nothing behind it. Codex read its own instructions and reported the drift; no
check would have. Worse, all four Hermes `SOUL.md` files still told those agents that memory was
Cognee, reached through an SSH tunnel on `127.0.0.1:8001`.

```bash
scripts/audit-stale-instructions.sh                 # the usual set
scripts/audit-stale-instructions.sh path/to/file    # or specific files
STALE_PATTERN='widgetron|old-thing' scripts/audit-stale-instructions.sh
```

It judges **paragraphs**, not lines, because these files are prose: a retirement is announced once
and discussed for several lines, and line matching reports every continuation of a note that is
already correct. A paragraph naming something retired passes when it also reads as history
("deleted", "retired", "no longer", a date). It fails when it reads as live guidance. Exit 1 lists
one line per offending paragraph.

Default set: `~/.claude/CLAUDE.md`, `~/CLAUDE.md`, `~/projects/CLAUDE.md`, `~/projects/AGENTS.md`,
`~/.codex/AGENTS.md`, `~/.hermes/SOUL.md`. Default terms: cognee, mem0, hyperswarm, and the dead
`8001` port.

Tests: `scripts/test-audit-stale-instructions.sh` (8 assertions). The first one asserts the audit
can **fail**, because an audit that always passes is the same silent success it exists to catch —
the first version of this script had a stray `next` that skipped every match, and reported a clean
sweep across six files that were not clean.
## Working in this repo

Bash and Python. No `package.json`, no build step, nothing to compile.

Nothing on this machine runs a hook straight out of this checkout. The live copies are
`~/.claude/scripts/` (capture gate, `mcp-headers.py`), the `com.screddy.gui-env` LaunchAgent
(`scripts/set-gui-env.sh`), and the `~/.local/bin` wrappers for `qwen`, `gbrowse` and `swarm`.

Run the checks before you install a changed script:

```bash
bash scripts/verify.sh
bash scripts/audit-stale-instructions.sh
```

`CLAUDE.md` carries the agent instructions.
