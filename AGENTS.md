# Claude Code Harness

This repository contains the Claude Code harness template and its Claude-facing
plugin sources. Keep examples free of company names, credentials, hostnames,
account IDs, and private project identifiers.

## Verification

Run before handoff:

```bash
find scripts -name '*.sh' -print0 | xargs -0 bash -n
scripts/verify.sh
scripts/audit-claude-harness.sh
scripts/test-statusline.sh
scripts/test-shared-hooks.sh
git diff --check
```

The audit is read-only. It checks this repository for Codex plugin manifests and,
when requested, the installed Claude settings.

## Working rules

- Keep Claude plugin manifests under their Claude-native directories.
- Keep Codex configuration, hooks, and plugin marketplaces in the separate
  `Screddyice/codex-harness` repository.
- Preserve idempotence in initialization and hook scripts.
- Do not modify a user's existing Claude setup unless an installation command names it.
- Every work branch gets a pull request, and every pull request updates `README.md`.
