#!/usr/bin/env bash
#
# browse-watchdog.sh — keep the gstack browse session alive, and leave evidence
# when it dies.
#
# The gstack headed browser died three times in one working session on
# 2026-08-20, each time silently: the CLI auto-started a replacement server in
# "launched" mode on a different port with a clean profile, so every command
# after the crash hit a browser the operator was not looking at. One of those
# deaths ate a logged-in IPRoyal session mid-purchase. The failure mode is not
# the crash; it is that nothing noticed.
#
# This watchdog does three things, in order of importance:
#   1. Notices. Polls the state file and the server every INTERVAL seconds.
#   2. Restores. Restarts the headed server with the same cleanup sequence
#      that works by hand (kill stale pid, clear profile locks, nohup connect)
#      and navigates back to the last URL it saw while healthy.
#   3. Files evidence. Each crash gets a report committed to the CRASH_BRANCH
#      of this repo and pushed, with one rolling draft PR collecting them, so
#      every crash leaves a diff instead of a shrug. One PR, not one per
#      crash: a flapping server must not spam the repo.
#
# It deliberately does NOT try to auto-fix anything. gstack is a third-party
# tool; a correct unattended fix for an arbitrary crash is not a thing. Set
# WATCHDOG_AUTOFIX=1 to additionally ask a headless `claude -p` session to
# analyse the report and append its findings — analysis, still not a merge.
#
# Usage:
#   browse-watchdog.sh <project-dir> [&]   # watch the browse session of a repo
#   WATCHDOG_INTERVAL=30 browse-watchdog.sh ~/projects/Screddyice/engagemate
#
# Stop with: touch <project-dir>/.gstack/watchdog-stop

set -uo pipefail

PROJECT_DIR="${1:?usage: browse-watchdog.sh <project-dir>}"
STATE_FILE="$PROJECT_DIR/.gstack/browse.json"
STOP_FILE="$PROJECT_DIR/.gstack/watchdog-stop"
BROWSE="$HOME/.claude/skills/gstack/browse/dist/browse"
PROFILE_DIR="$HOME/.gstack/chromium-profile"
REPORT_ROOT="$HOME/.gstack/crash-reports"
LAST_URL_FILE="$HOME/.gstack/watchdog-last-url"
HARNESS_REPO="$HOME/projects/Screddyice/claude-code-harness"
CRASH_BRANCH="crash-reports"
INTERVAL="${WATCHDOG_INTERVAL:-20}"
# A server that cannot stay up for an hour needs a human, not a supervisor.
MAX_RESTARTS_PER_HOUR="${WATCHDOG_MAX_RESTARTS:-4}"

mkdir -p "$REPORT_ROOT"
restart_log="$REPORT_ROOT/.restart-times"

log() { printf '[watchdog %s] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }

browse_cmd() {
    # The CLI keys its state file to the current directory, and any command
    # issued while no server is running AUTO-SPAWNS a launched-mode squatter
    # there. Both bites happened on this watchdog's first live run: probing
    # from the wrong cwd created a second server for the wrong repo, then
    # reported the healthy one dead. Every browse call goes through here,
    # pinned to the project.
    ( cd "$PROJECT_DIR" && timeout "${2:-20}" "$BROWSE" $1 2>/dev/null )
}

healthy() {
    # Healthy means: state file exists, its pid is alive, and the server
    # answers `status` reporting headed mode. The pid check comes FIRST --
    # calling `status` with no live server auto-spawns the squatter that
    # then blocks the real reconnect on the port.
    [[ -f "$STATE_FILE" ]] || return 1
    local pid
    pid="$(grep -o '"pid":[[:space:]]*[0-9]*' "$STATE_FILE" | grep -o '[0-9]*')" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    browse_cmd status | grep -q "Mode: headed"
}

recent_restarts() {
    [[ -f "$restart_log" ]] || { echo 0; return; }
    local cutoff
    cutoff=$(( $(date +%s) - 3600 ))
    awk -v c="$cutoff" '$1 > c' "$restart_log" | wc -l | tr -d ' '
}

capture_report() {
    local ts="$1" dir="$REPORT_ROOT/$ts"
    mkdir -p "$dir"
    {
        echo "crash detected: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "project: $PROJECT_DIR"
        echo "last healthy url: $(cat "$LAST_URL_FILE" 2>/dev/null || echo unknown)"
        echo
        echo "== state file =="
        cat "$STATE_FILE" 2>/dev/null || echo "(missing)"
        echo
        echo "== processes matching browse/chromium-profile =="
        pgrep -fl "browse|chromium-profile" 2>/dev/null || echo "(none)"
        echo
        echo "== port 34567 holders =="
        lsof -ti :34567 2>/dev/null | while read -r p; do
            echo "$p: $(ps -o command= -p "$p" 2>/dev/null | head -c 200)"
        done
    } > "$dir/report.txt"
    # The connect log is the closest thing to a stack trace the server leaves.
    for f in "$HOME"/.gstack/browse*.log /private/tmp/claude-*/*/scratchpad/browse-connect*.log; do
        [[ -f "$f" ]] && tail -100 "$f" > "$dir/$(basename "$f").tail" 2>/dev/null
    done
    echo "$dir"
}

file_report() {
    # Commit the report to the rolling crash branch and make sure exactly one
    # draft PR collects them. Failure to file must never block the restart,
    # so everything here is best-effort.
    local dir="$1" ts="$2"
    ( cd "$HARNESS_REPO" || exit 0
      git fetch -q origin "$CRASH_BRANCH" 2>/dev/null
      if git rev-parse -q --verify "origin/$CRASH_BRANCH" >/dev/null; then
          git worktree add -q "/tmp/crash-wt-$ts" "$CRASH_BRANCH" 2>/dev/null \
              || git worktree add -q "/tmp/crash-wt-$ts" -b "$CRASH_BRANCH" "origin/$CRASH_BRANCH"
      else
          git worktree add -q "/tmp/crash-wt-$ts" -b "$CRASH_BRANCH" origin/main
      fi
      cd "/tmp/crash-wt-$ts" || exit 0
      mkdir -p crash-reports
      cp -R "$dir" "crash-reports/$ts"
      git add crash-reports
      git commit -qm "crash: gstack browse died $ts, evidence attached"
      git push -q origin "$CRASH_BRANCH"
      gh pr list --head "$CRASH_BRANCH" --state open --json number 2>/dev/null \
          | grep -q '"number"' \
          || gh pr create --draft --head "$CRASH_BRANCH" \
               --title "crash reports: gstack browse session deaths" \
               --body "Rolling evidence from browse-watchdog.sh. Each commit is one crash: state file, process table, port holders, connect-log tail. Filed automatically; investigate before closing." \
               2>/dev/null
      cd "$HARNESS_REPO" && git worktree remove -f "/tmp/crash-wt-$ts" 2>/dev/null
    ) || log "filing crash report failed (non-fatal)"
    if [[ "${WATCHDOG_AUTOFIX:-0}" == "1" ]] && command -v claude >/dev/null; then
        claude -p "Read $dir/report.txt and the log tails beside it. Diagnose why the gstack browse server died. Append your analysis as analysis.md in that directory. Do not modify anything else." \
            --allowedTools "Read,Write" >/dev/null 2>&1 &
    fi
}

restart_browser() {
    local pid
    pid="$(grep -o '"pid":[[:space:]]*[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*')"
    [[ -n "${pid:-}" ]] && kill -9 "$pid" 2>/dev/null
    rm -f "$STATE_FILE"
    lsof -ti :34567 2>/dev/null | xargs kill -9 2>/dev/null
    for lf in SingletonLock SingletonSocket SingletonCookie; do
        rm -f "$PROFILE_DIR/$lf" 2>/dev/null
    done
    sleep 2
    ( cd "$PROJECT_DIR" && nohup "$BROWSE" connect \
        > "$REPORT_ROOT/last-restart-connect.log" 2>&1 < /dev/null & )
    # Wait for connect to write its own state file rather than sleeping blind:
    # probing too early auto-spawns a squatter that steals the port.
    local waited=0
    until grep -q '"mode": *"headed"' "$STATE_FILE" 2>/dev/null || (( waited >= 45 )); do
        sleep 3; waited=$(( waited + 3 ))
    done
    local url
    url="$(cat "$LAST_URL_FILE" 2>/dev/null)"
    if [[ -n "$url" && "$url" != "about:blank" ]]; then
        browse_cmd "goto $url" 60 >/dev/null
        browse_cmd focus >/dev/null
    fi
}

log "watching $PROJECT_DIR every ${INTERVAL}s (stop: touch $STOP_FILE)"
while true; do
    [[ -f "$STOP_FILE" ]] && { rm -f "$STOP_FILE"; log "stop requested"; exit 0; }
    if healthy; then
        url="$(browse_cmd url 15 | tail -1)"
        [[ -n "$url" && "$url" == http* ]] && printf '%s' "$url" > "$LAST_URL_FILE"
    else
        ts="$(date -u '+%Y%m%dT%H%M%SZ')"
        log "browse session unhealthy, capturing evidence ($ts)"
        dir="$(capture_report "$ts")"
        if (( $(recent_restarts) >= MAX_RESTARTS_PER_HOUR )); then
            log "restart budget exhausted ($MAX_RESTARTS_PER_HOUR/hour); filing report and stopping"
            file_report "$dir" "$ts"
            exit 1
        fi
        date +%s >> "$restart_log"
        restart_browser
        if healthy; then
            log "restarted and restored"
        else
            log "restart did not come back healthy; will retry next tick"
        fi
        file_report "$dir" "$ts"
    fi
    sleep "$INTERVAL"
done
