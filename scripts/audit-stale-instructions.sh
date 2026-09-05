#!/usr/bin/env bash
# Report agent instruction files that still name a retired component.
#
# WHY: instruction files are read by every agent on every session and are never
# executed, so a component can be deleted from the machine while every agent is
# still told it is canonical. On 2026-09-04 Cognee was removed from the whole
# fleet and `~/.codex/AGENTS.md` went on saying "Memory = Cognee", naming a
# plugin that no longer existed and a port with nothing behind it. Codex read it
# and reported the drift; nothing else would have.
#
# Prose that names a retirement on purpose is fine and common — "Cognee was
# deleted on 2026-09-04" should not be an issue — so a line is only reported
# when it reads as live guidance rather than history.
#
# Usage: audit-stale-instructions.sh [file ...]   (defaults to the usual set)
set -uo pipefail
TMPOUT=$(mktemp); trap 'rm -f "$TMPOUT"' EXIT

RETIRED_DEFAULT='cognee|mem0|hyperswarm|127\.0\.0\.1:8001|localhost:8001'
RETIRED="${STALE_PATTERN:-$RETIRED_DEFAULT}"
# A line that dates or retires the thing is history, not guidance.
HISTORY='retired|deleted|removed|decommission|replaced by|superseded|no longer|was |were |formerly|legacy|archive|obsolete|stopped|went dry|dead|until 20|scripts/hooks/|do not (use|reintroduce|resurrect)'

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  files=(
    "$HOME/.claude/CLAUDE.md"
    "$HOME/CLAUDE.md"
    "$HOME/projects/CLAUDE.md"
    "$HOME/projects/AGENTS.md"
    "${CODEX_HOME:-$HOME/.codex}/AGENTS.md"
    "$HOME/.hermes/SOUL.md"
  )
fi

issues=0
checked=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  checked=$((checked + 1))
  # Judge a PARAGRAPH, not a line. These files are prose: a retirement is
  # announced once and then discussed for several lines, so line-by-line
  # matching reports every continuation line of a note that is already correct.
  awk -v RS='' -v file="${f/#$HOME/~}" -v retired="$RETIRED" -v history="$HISTORY" '
    {
      block = tolower($0)
      if (block !~ tolower(retired)) next        # nothing retired in this paragraph
      if (block ~ tolower(history)) next          # it is written as history, which is correct
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (tolower(lines[i]) ~ tolower(retired)) {
          gsub(/^[ \t]+/, "", lines[i])
          printf "%s: %s\n", file, substr(lines[i], 1, 110)
          break
        }
      }
    }
  ' "$f" > "$TMPOUT" 2>/dev/null || true
  if [ -s "$TMPOUT" ]; then cat "$TMPOUT"; issues=$((issues + $(wc -l < "$TMPOUT"))); fi
done

if [ "$issues" -gt 0 ]; then
  printf '\n%d paragraph(s) across %d file(s) still present a retired component as current.\n' "$issues" "$checked"
  printf 'Each is guidance every agent reads on every session. Rewrite it, or say when it was retired.\n'
  exit 1
fi
printf 'No retired component is presented as current across %d instruction file(s).\n' "$checked"
