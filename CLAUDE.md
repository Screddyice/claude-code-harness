# claude-code-harness

## What this is

The shared harness for Shawn's Claude Code and Codex sessions: the hook
implementations both hosts register, the operational scripts around them, and an
example plugin marketplace.

**This repo is where the hooks actually live.** `~/.claude/settings.json` and
`~/.codex/hooks.json` register these paths directly, and the same-named files under
`~/.claude/scripts/` are one-line compat wrappers that `exec` into here. Edit the
implementation in this repo, never the wrapper.

> claude-mem was removed 2026-08-02. Do not reinstall the thedotmack plugin, host
> proxy, mcp-search, or Grok mem hooks. Shared observation memory is gone from this
> harness; Cognee replaced it.

## Stack

Bash and Python. No `package.json`, no build step, and no npm anything — earlier
versions of this file listed `npm run build` / `npm run lint` / `npm test`, none of
which exist.

## Hooks it provides

| Hook | Event | Behavior |
|---|---|---|
| `scripts/hooks/auto-pr-push.sh` | PostToolUse (both hosts) | Pushes and opens a draft PR on the first commit, for owned orgs only (`teamnebula-ai`, `Screddyice`) |
| `scripts/hooks/enforce-pr-claude.sh` | Stop (Claude) | Blocks the stop once when a branch has commits but no PR; emits `{decision,reason}` |
| `scripts/hooks/enforce-pr-codex.sh` | Stop (Codex) | Same rule, emitting Codex's `{continue,stopReason,systemMessage}` contract |
| `scripts/hooks/local-diff-review.sh` | Stop (Claude) | Local qwen review of the branch diff. Gated on `LOCAL_REVIEW`, which `~/.claude/settings.json` currently sets to `0`, so it exits immediately |
| `scripts/hooks/local-diff-review-codex.sh` | Stop (Codex) | The Codex copy of the same reviewer |

## Commands

```bash
bash -n scripts/hooks/<hook>.sh          # syntax check before registering
./scripts/test-auto-pr-push-base.sh      # auto-pr-push base-branch behavior
./scripts/test-auto-pr-push-merged-guard.sh
./scripts/test-auto-pr-push-elsewhere-guard.sh
```

A hook that exits non-zero blocks the tool call that triggered it, so run the syntax
check before you register anything.

## Rules that apply here

Machine hard rules: `~/.claude/CLAUDE.md`. Workspace rules: `~/projects/CLAUDE.md`
and `~/projects/AGENTS.md`. Org identity comes from the git `origin` remote.

Durable facts go to **Cognee**, the only memory on this machine. Search it before
re-deriving a past decision, and write findings back with `cognee-remember`. The
`.claude-harness/memory/` tree in this repo is scaffolding, not a live memory layer.

Every branch gets a PR, and every PR updates this repo's README.
