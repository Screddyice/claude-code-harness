> **claude-mem removed 2026-08-02.** Do not reinstall the thedotmack plugin, host proxy, mcp-search, or Grok mem hooks. Shared observation memory is gone from this harness.

# Codex Harness

This repository is the sanitized, reusable Codex harness template. Keep examples free
of company names, credentials, hostnames, account IDs, and private project identifiers.

## Verification

Run before handoff:

```bash
find scripts -name '*.sh' -print0 | xargs -0 bash -n
scripts/test-codex-local-diff-review.sh
scripts/test-shared-hooks.sh
scripts/test-track-branch-pr.sh
scripts/test-install-llmjury-orchestration.sh
scripts/audit-codex-migration.sh /path/to/workspace
git diff --check
```

The audit is read-only. Its default mode validates compatibility while reporting legacy
Claude surfaces; `--strict` treats every legacy-only path as a failure.

## Working Rules

- Preserve idempotence in initialization scripts.
- Prefer documented Codex-native surfaces: `AGENTS.md`, `.codex/config.toml`, hooks,
  skills, plugins, MCP, and `codex exec`.
- Keep `CLAUDE.md` fallback support during staged migrations; do not imply that fallback
  files are already semantically adapted for Codex.
- Do not modify or delete a user's existing Claude setup during migration.
- After the first commit on a work branch, run `scripts/track-branch-pr.sh` to push it
  and open a draft PR. Run it after later commits so review tracks ongoing progress.
- Never leave a committed work branch without a PR, and never self-merge it.

## Workspace root (Shawn Mac)

On this machine the multi-org workspace is `~/projects` (not a single git repo). Harness
hooks install into user config (`~/.claude`, `~/.codex`) so they apply to
**any** cwd under `~/projects`, regardless of org folder. Workspace instructions live at
`~/projects/AGENTS.md` and `~/projects/CLAUDE.md`; org identity is still git `origin`.
Do not require re-installing the harness per org.

## Retired hosts

**Grok (removed 2026-08-18).** The Grok Build CLI, `~/.grok`, its native hook slice, and
`scripts/install-grok-harness.sh` were removed from this machine and this repo. Do not
re-add a Grok host without re-deriving the hard rules that governed it — chiefly that
`[compat.claude] hooks` had to stay false, because importing Claude's full hook chain
(including the Ollama diff reviewer) into every Grok tool call kernel-panicked this host.

**Mem compression is host-routed (2026-08-01):** Codex sessions compress with Codex CLI,
Claude with Claude CLI (Codex fallback on weekly limit). Local Ollama `qwen3.5:4b-mem` is
only for local/qwen sessions.
