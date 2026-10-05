# claude-code-harness

This repository is the Claude Code side of the local agent setup. It carries the
Claude-facing plugin sources, Claude hooks, status tooling, and shared utilities.

Codex has a separate source of truth at
[`Screddyice/codex-harness`](https://github.com/Screddyice/codex-harness). Keep Codex
configuration, Codex plugin manifests, and Codex-only installers there. This repo
must not install or register Codex plugins.

`holyclaude-cloud/` is a vendored Claude plugin source. Make upstream changes in
`Screddyice/holyclaude-cloud` and re-vendor them here. `hermes/plugins/cmem/` is the
ClaudeMem provider source used by Hermes hosts. The machine-level ClaudeMem plugin
is managed by ClaudeMem itself.

The harness has no Node build. Use the shell and Python checks in `AGENTS.md` and
`README.md`; do not invent an npm build step.
