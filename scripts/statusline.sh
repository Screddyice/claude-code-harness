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

# A routed session has Backdoor in its request path. Routing alone says nothing
# about which model answered, so a healthy routed cloud session gets no badge.
base_url="${ANTHROPIC_BASE_URL:-}"
proxy_url="${HTTPS_PROXY:-}"
if [ -z "$base_url" ] && [ -z "$proxy_url" ]; then
  ancestor=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
  for _ in 1 2 3 4; do
    if [ -z "$ancestor" ] || [ "$ancestor" = "0" ] || [ "$ancestor" = "1" ]; then
      break
    fi
    command_name=$(ps -o comm= -p "$ancestor" 2>/dev/null | xargs basename 2>/dev/null)
    if [ "$command_name" = "claude" ]; then
      env_dump=$(ps -E -o command= -p "$ancestor" 2>/dev/null | tr ' ' '\n')
      base_url=$(printf '%s\n' "$env_dump" | grep -m1 '^ANTHROPIC_BASE_URL=' | cut -d= -f2-)
      proxy_url=$(printf '%s\n' "$env_dump" | grep -m1 '^HTTPS_PROXY=' | cut -d= -f2-)
      break
    fi
    ancestor=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d ' ')
  done
fi

routed=0
case "$proxy_url" in
  http://127.0.0.1:8084|http://127.0.0.1:8084/|http://localhost:8084|http://localhost:8084/)
    routed=1 ;;
esac
case "$base_url" in
  http://127.0.0.1:8083|http://127.0.0.1:8083/|http://localhost:8083|http://localhost:8083/)
    routed=1 ;;
esac

# Breaker state is global, so a direct Claude session must also prove it is
# routed before claiming local service. Invalid state fails closed.
failover_active=0
state_file="${BACKDOOR_STATE_FILE:-$HOME/.backdoor/failover-state.json}"
if [ "$routed" -eq 1 ] && [ -r "$state_file" ] && jq -e '
  (.failover_active == true)
  and (.active_sources | type == "array")
  and any(.active_sources[]?; . == "anthropic")
  and (.pid | type == "number" and . > 1 and . == floor)
' "$state_file" >/dev/null 2>&1; then
  state_pid=$(jq -r '.pid' "$state_file" 2>/dev/null)
  case "$state_pid" in
    ''|*[!0-9]*) state_pid="" ;;
  esac
  if [ -n "$state_pid" ] && kill -0 "$state_pid" 2>/dev/null; then
    router_command=$(ps -o command= -p "$state_pid" 2>/dev/null)
    case "$router_command" in
      *" -m src.proxy.serve"*|backdoor-router|backdoor-router\ *|*/backdoor-router|*/backdoor-router\ *)
        failover_active=1 ;;
    esac
  fi
fi

model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lc" in
  qwen|qwen-fast|qwen38-obliterated|qwen38-action)
    model_part="QWEN LOCAL" ;;
  *)
    model_part="$model" ;;
esac

if [ "$failover_active" -eq 1 ]; then
  model_part="QWEN LOCAL · BACKDOOR ON"
elif [ "$routed" -eq 0 ]; then
  model_part="$model_part · BACKDOOR OFF"
fi

parts="$model_part"
[ -n "$cwd_short" ] && parts="$parts · $cwd_short"
parts="$parts · shells: $shells"
[ -n "$legion_part" ] && parts="$parts · $legion_part"

printf '%s' "$parts"
