# Workspace root: ~/projects (Grok)

Canonical multi-org workspace is `/Users/screddy/projects`. Start Grok there or under any org/repo path. This is not one git repo.

## Instruction layers

| Layer | Path |
|-------|------|
| Machine (Claude global, via compat) | `~/.claude/CLAUDE.md` when rules/skills compat is on |
| Workspace | `~/projects/CLAUDE.md` + `~/projects/AGENTS.md` |
| Grok rules | `~/.grok/rules/*` (this file + claude-mem-context) |
| Org folder | `tmn/`, `Screddyice/`, `BH/` thin CLAUDE/AGENTS |
| Repo | nearest git root CLAUDE/AGENTS — **wins on conflict** |

## Hard rules for this machine

1. **Org identity** = `git remote get-url origin` on the nearest `.git`, not the folder name.
2. **Skills** = global. Config scans `~/.agents/skills`, `~/.claude/skills`, `~/.grok/skills*`. Compat Claude skills stay enabled; hooks/mcps stay **disabled**.
3. **Harness hooks** are native only: `~/.grok/hooks/{claude-mem,hyperswarm,load-projects-env,pr-tracking}.json`. Never set `[compat.claude] hooks = true`.
4. **claude-mem** platform_source is `grok`. Compression uses **Grok CLI** via host proxy (`:11435`), not Ollama. Ops: `~/.claude-mem/HOST-LLM-ROUTING.md`.
5. **Credentials**: `~/projects/.env` (wrapper + load-projects-env hook). Never print secrets.
6. **PR-per-branch** applies to owned orgs (`teamnebula-ai`, `Screddyice`) via `pr-tracking.json`.
7. When you enter a specific repo, read its local AGENTS/CLAUDE before coding.
