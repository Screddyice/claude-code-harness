# Codex Harness

This repository is the sanitized, reusable Codex harness template. Keep examples free
of company names, credentials, hostnames, account IDs, and private project identifiers.

## Verification

Run before handoff:

```bash
bash -n scripts/*.sh
scripts/test-codex-local-diff-review.sh
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
