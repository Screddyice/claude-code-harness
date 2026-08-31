# Failover-Only Backdoor Status-Line Plan

**Goal:** Make Claude's status line show `BACKDOOR ON` only while a routed Claude session is being served by local Qwen during confirmed Anthropic failover.

**Scope:** Change the canonical harness source and its fixture tests. Do not edit `~/.claude/statusline.sh`, `~/.claude/settings.json`, Backdoor, launchd, routing variables, or breaker state.

## Required states

| Session state | Status text |
|---|---|
| Routed cloud model, breaker closed | No Backdoor badge |
| Direct cloud model | `BACKDOOR OFF` |
| Deliberate local Qwen model | `QWEN LOCAL` |
| Routed Claude request, Anthropic failover active | `QWEN LOCAL · BACKDOOR ON` |
| Missing, malformed, dead-PID, wrong-process, or Codex-only state | Never `BACKDOOR ON` |

## State proof

The status script reads `${BACKDOOR_STATE_FILE:-$HOME/.backdoor/failover-state.json}` without writing it. `BACKDOOR ON` requires all of these checks:

1. The Claude process inherited the `:8084` forward proxy or `:8083` Anthropic base URL.
2. The state is valid JSON with `failover_active=true`.
3. `active_sources` is an array containing `anthropic`.
4. `pid` is a positive integer for a live process.
5. `ps -o command=` identifies that PID as the Backdoor router through `src.proxy.serve` or a `backdoor-router` command name.

The model display name remains the source for deliberate Qwen routes. Active Anthropic failover overrides a cloud display name with `QWEN LOCAL` because Qwen is serving the turn even if Claude still labels the requested model as Opus.

## Test-first sequence

1. Add `scripts/test-statusline.sh` with fixtures for the five required states and the four fail-closed state errors.
2. Run it against the current canonical script and confirm the routed/failover assertions fail.
3. Add routing detection, local-model labeling, and read-only breaker-state validation to `scripts/statusline.sh`.
4. Run the fixture test, `bash -n`, the repository shell verification set, and `git diff --check`.
5. Document the badge contract and the source-versus-installed boundary in `README.md`.
6. Push the draft PR and stop before installation.

## Rollback boundary

Reverting this branch restores the prior canonical status line. Since this task does not install the script, rollback changes no running Claude or Codex session. A later installation needs separate approval, a backup, `bash -n`, fixture tests, and an atomic rename.
