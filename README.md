# codex-harness

A starter template for organizing a multi-company [OpenAI Codex CLI](https://github.com/openai/codex)
workspace.

This is **not** a fork of Codex itself. It is the thin local layer around Codex:
sanitized `AGENTS.md` templates, a conservative `~/.codex/config.toml` example,
per-repo `.codex-harness/` scaffolding, and a local Codex plugin marketplace stub.

The repo was adapted from a Claude Code harness. The Claude-specific surfaces
(`~/.claude/settings.json`, SessionStart hooks, status lines, and `CLAUDE.md`) are
intentionally replaced with Codex-native concepts.

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
| SessionStart hook | Optional Codex `hooks.json`, explicit `scripts/init-codex-harness.sh`, or your own shell wrapper |
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
```

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

Codex has a hook feature in current CLI builds, but hook behavior and payload details
can vary by version. This harness includes `examples/hooks.json.example` for users who
want auto-init behavior similar to the old Claude SessionStart hook.

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
