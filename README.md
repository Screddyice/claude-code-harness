# claude-code-harness

A starter template for organizing a multi-company [Claude Code](https://claude.com/claude-code) workspace.

This is **not** a fork of Claude Code itself (which is Anthropic's proprietary CLI), and
it does **not** bundle the third-party plugins this setup depends on. It is the thin
custom layer — sanitized settings, hook scripts, a multi-company `CLAUDE.md` template,
and a local plugin marketplace stub — that sits on top of the existing OSS Claude Code
plugin ecosystem.

## What's inside

```
claude-code-harness/
├── examples/
│   ├── CLAUDE.md.global.example      # ~/.claude/CLAUDE.md template
│   ├── CLAUDE.md.workspace.example   # ~/projects/CLAUDE.md template (multi-company)
│   └── settings.json.example         # ~/.claude/settings.json template
├── scripts/
│   ├── auto-init-harness.sh          # SessionStart hook: auto-init harness in any git repo
│   └── statusline.sh                 # Custom status line: model · cwd · shells
└── marketplace/
    └── example-local/                # Example local plugin marketplace
```

## Who this is for

You operate multiple companies / orgs out of a single workspace directory (e.g.
`~/projects/`), each with its own:

- Git history
- MCP / integration accounts (Composio, Apify, etc.)
- Cloud infrastructure (separate AWS accounts, separate Tailscale tailnets)
- Webhook receivers and event handlers
- Project tracker (Linear, Jira, etc.)

And you want a documented architecture pattern for keeping each company's automations,
credentials, and agent context isolated — while sharing one Claude Code setup.

## What it gives you

1. **Multi-company workspace map** — a `CLAUDE.md` template that documents where each
   company lives, how MCP servers are scoped per org, how AWS / overlay-network /
   webhook infrastructure is separated, and the anti-patterns to avoid (cross-wired
   credentials, shared overlay networks, etc.).
2. **Sanitized `settings.json`** — `enabledPlugins`, `extraKnownMarketplaces`, hook
   wiring, and a recommended permissions/`statusLine` setup.
3. **`auto-init-harness.sh`** — a `SessionStart` hook that auto-creates a
   `.claude-harness/` directory in any git repo Claude Code opens, with a hook for
   skipping high-stakes client repos (lockdown pattern).
4. **`statusline.sh`** — a minimal jq-driven status line showing model, working
   directory, and the count of active CLI sessions.
5. **Local marketplace stub** — example directory layout for shipping in-house plugins
   to your own machine without publishing them publicly.

## Recommended third-party plugins

This template assumes you have these public OSS plugins installed. None of them are
bundled in this repo — install them separately.

| Plugin | What it gives you |
|--------|-------------------|
| [gstack](https://github.com/garrytan/gstack) | Slash-command "specialists" for planning, design, QA, ship, etc. |
| [superpowers](https://github.com/anthropics/claude-plugins) | Skill discipline (TDD, brainstorming, debugging, plans) |
| [holyclaude / legion](https://github.com/holyclaude/holyclaude-cloud) | Parallel agent dispatch and orchestration |
| [claude-mem](https://github.com/thedotmack/claude-mem) | Persistent cross-session memory |
| [frontend-design](https://github.com/anthropics/claude-plugins) | Polished frontend code generation |
| [playwright](https://github.com/anthropics/claude-plugins) | Browser automation MCP |
| [deep-research](https://github.com/daymade/claude-code-skills) | Deep research workflow |
| [claude-harness](https://github.com/panayiotism/claude-harness-marketplace) | Per-repo harness directory the `auto-init-harness.sh` script wraps |

## Installation

```bash
# 1. Clone this repo
git clone https://github.com/Screddyice/claude-code-harness.git
cd claude-code-harness

# 2. Copy the example settings into place (back up your own first)
cp ~/.claude/settings.json ~/.claude/settings.json.backup
cp examples/settings.json.example ~/.claude/settings.json

# 3. Copy the example global CLAUDE.md (back up your own first)
cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.backup 2>/dev/null || true
cp examples/CLAUDE.md.global.example ~/.claude/CLAUDE.md
# Edit ~/.claude/CLAUDE.md to replace <COMPANY> placeholders with your own orgs.

# 4. Install hook scripts
mkdir -p ~/.claude/scripts
cp scripts/auto-init-harness.sh ~/.claude/scripts/
cp scripts/statusline.sh ~/.claude/
chmod +x ~/.claude/scripts/auto-init-harness.sh ~/.claude/statusline.sh

# 5. Drop the workspace CLAUDE.md template at your workspace root
cp examples/CLAUDE.md.workspace.example ~/projects/CLAUDE.md
# Edit ~/projects/CLAUDE.md with your specific companies and infrastructure.

# 6. Install the upstream third-party plugins listed above.
```

## Sanitization

This repo intentionally contains **no** secrets, API keys, OAuth tokens, server IPs,
account IDs, client names, team member names, or internal project identifiers. All
company-specific content in the templates uses `<COMPANY_A>` / `<COMPANY_B>` /
`<COMPANY_C>` placeholders. If you find anything that looks like leaked credentials or
PII, please open an issue.

## License

[MIT](LICENSE)

## Acknowledgements

Most of the value in a Claude Code harness comes from the upstream OSS plugin ecosystem
linked above — this repo just documents one opinionated way of composing those pieces
into a multi-company setup. Big thanks to the authors of gstack, superpowers,
holyclaude, claude-mem, and the rest.
