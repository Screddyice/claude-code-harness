#!/bin/bash
# Custom Claude Code status line: shows model, working directory, and active session count.
# Wire via "statusLine.command" in ~/.claude/settings.json.

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
model=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

cwd_short="${cwd/#$HOME/~}"

shells=0
for f in "$HOME"/.claude/sessions/*.json; do
  [ -f "$f" ] || continue
  pid=$(basename "$f" .json)
  kill -0 "$pid" 2>/dev/null || continue
  ep=$(jq -r '.entrypoint // ""' "$f" 2>/dev/null)
  [ "$ep" = "cli" ] && shells=$((shells+1))
done

parts="$model"
[ -n "$cwd_short" ] && parts="$parts · $cwd_short"
parts="$parts · shells: $shells"

printf '%s' "$parts"
