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

# Legion worker counts for the legion run in THIS terminal's repo.
# Walk up from cwd to the first .legion/state.json, then count in-flight
# workers split by target: cloud (Modal), local (worktree), qwen (local-model).
# Only shown while something is actually running.
legion_part=""
d="$cwd"
while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
  state="$d/.legion/state.json"
  if [ -f "$state" ]; then
    read -r cloud_n local_n qwen_n < <(jq -r '
      [.tasks[]? | select(.status == "in_flight")] as $live
      | [ ($live | map(select(.target == "cloud"))        | length),
          ($live | map(select(.target == "local"))        | length),
          ($live | map(select(.target == "local-model"))  | length) ]
      | @tsv
    ' "$state" 2>/dev/null)
    cloud_n=${cloud_n:-0}; local_n=${local_n:-0}; qwen_n=${qwen_n:-0}
    if [ $((cloud_n + local_n + qwen_n)) -gt 0 ]; then
      legion_part="legion ☁$cloud_n 💻$local_n 🐦$qwen_n"
    fi
    break
  fi
  d=$(dirname "$d")
done

parts="$model"
[ -n "$cwd_short" ] && parts="$parts · $cwd_short"
parts="$parts · shells: $shells"
[ -n "$legion_part" ] && parts="$parts · $legion_part"

printf '%s' "$parts"
