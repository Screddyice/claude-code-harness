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

## Grok (native, not compat import)

Grok lives under `~/.grok` with its own hooks and scripts. Install with
`scripts/install-grok-harness.sh`. Hard rules:

- Keep `[compat.claude] hooks = false` and `mcps = false`. Enabling them imports Claude
  Code's full hook chain (including the Ollama diff reviewer) into every Grok tool call
  and has kernel-panicked this host.
- Wire PR tracking and claude-mem through `examples/grok/*.json` + `scripts/grok/*`,
  never by turning on Claude compat hooks.
- Do not add `local-diff-review` to Grok Stop hooks.
- claude-mem uses platform source `grok`; context injects via
  `~/.grok/rules/claude-mem-context.md` and MCP `mcp-search`.
- **Mem compression is host-routed (2026-08-01):** Grok sessions compress with
  Grok CLI, Codex with Codex CLI, Claude with Claude CLI (Codex fallback on
  weekly limit). Local Ollama `qwen3.5:4b-mem` is only for local/qwen sessions.
  Host proxy: `~/.local/bin/claude-mem-host-proxy.py` on `:11435`; settings use
  model `claude-mem-auto`. See `~/.claude-mem/HOST-LLM-ROUTING.md`. A healthy
  Grok session must not load Ollama solely for mem.
