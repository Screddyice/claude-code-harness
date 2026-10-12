#!/usr/bin/env bash
# oauth-expiry-monitor.sh — event-driven sampler for Claude Code's OAuth state.
#
# WHY THIS EXISTS
#   Claude Code's "Your login expires in N day(s) · run /login to renew" banner
#   reads ONLY refreshTokenExpiresAt from the macOS keychain item
#   "Claude Code-credentials". daysLeft is Math.ceil(), so any remaining fraction
#   of a day renders as "1 day" — a refresh token pinned near its expiry says
#   "1 day" every single day while auth keeps working fine. The 8-hour access
#   token rotating is normal and is NOT what the banner reads.
#
#   The banner is also computed once per session at mount and memoized, so a
#   long-running session keeps showing whatever was true when it launched.
#
# WHAT IT DOES
#   Appends one JSON snapshot per run to ~/.claude/oauth-expiry.log, and flags:
#     - REGRESSION: refreshTokenExpiresAt moved BACKWARDS vs the last sample
#       (that is a stale credential blob being written back over a fresh one)
#     - EXPIRING:   refresh token is inside the 3-day banner window
#
#   Event-driven only (SessionStart / SessionEnd). No polling timer, per the
#   workspace no-wake-to-check rule.
#
# USAGE
#   oauth-expiry-monitor.sh            # sample + emit hook JSON if action needed
#   oauth-expiry-monitor.sh --quiet    # sample only, never emit (SessionEnd)
#
# Always exits 0. This must never block a session.

set -uo pipefail

MODE="${1:-}" \
LOG_PATH="${LOG_PATH:-${HOME}/.claude/oauth-expiry.log}" \
NOTIFY_STAMP="${NOTIFY_STAMP:-${HOME}/.claude/.oauth-expiry-notified}" \
python3 - <<'PY' 2>/dev/null || exit 0
import os, sys, json, math, subprocess, datetime

LOG    = os.environ["LOG_PATH"]
STAMP  = os.environ["NOTIFY_STAMP"]
QUIET  = os.environ.get("MODE") == "--quiet"
WINDOW = 3 * 86400          # matches Claude Code's own banner threshold

def bail():
    sys.exit(0)

try:
    # OAUTH_MONITOR_TEST_JSON is a test seam so the alert paths can be exercised
    # without touching the real keychain. Unset in normal operation.
    blob = os.environ.get("OAUTH_MONITOR_TEST_JSON")
    if not blob:
        blob = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=8, check=True).stdout
    o = json.loads(blob)
except Exception:
    bail()                  # no keychain access / not logged in: stay silent

o = o.get("claudeAiOauth", o)
ref = o.get("refreshTokenExpiresAt")
if not isinstance(ref, (int, float)):
    bail()

now      = datetime.datetime.now(datetime.timezone.utc)
secs     = ref / 1000 - now.timestamp()
days     = secs / 86400

# --- compare against the previous sample -----------------------------------
prev = None
try:
    with open(LOG) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    prev = json.loads(line)
                except ValueError:
                    pass
except OSError:
    pass

regressed_by = 0.0
if prev and isinstance(prev.get("refreshTokenExpiresAt"), (int, float)):
    delta_ms = prev["refreshTokenExpiresAt"] - ref
    if delta_ms > 60_000:          # >1 min backwards is a real rollback
        regressed_by = delta_ms / 86_400_000

# --- record ----------------------------------------------------------------
entry = {
    "ts": now.isoformat(timespec="seconds"),
    "accessExpiresAt": o.get("expiresAt"),
    "refreshTokenExpiresAt": ref,
    "refreshDaysLeft": round(days, 3),
    "subscriptionType": o.get("subscriptionType"),
}
if regressed_by:
    entry["regressedDays"] = round(regressed_by, 3)
try:
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")
except OSError:
    pass

if QUIET:
    bail()

# --- decide whether to say anything ----------------------------------------
msgs = []
if regressed_by:
    msgs.append(
        f"Claude login: refresh-token expiry moved BACKWARDS by {regressed_by:.2f} days "
        f"since the last sample. Something wrote a stale credential blob over the fresh "
        f"one. See ~/.claude/oauth-expiry.log."
    )
if 0 < secs <= WINDOW:
    d = math.ceil(secs / 86400)
    msgs.append(
        f"Claude login: refresh token expires in {secs/3600:.1f}h (banner will say "
        f'"{d} day{"" if d == 1 else "s"}" until you actually re-auth). Run /login once — '
        f"ordinary 8h access-token refreshes do NOT extend this window."
    )
elif secs <= 0:
    msgs.append("Claude login: refresh token has EXPIRED. Run /login.")

if not msgs:
    bail()

# throttle the desktop notification to once per 12h
# MONITOR_NO_NOTIFY suppresses it entirely (tests, headless/cron runs).
try:
    last = os.path.getmtime(STAMP)
except OSError:
    last = 0
if not os.environ.get("MONITOR_NO_NOTIFY") and now.timestamp() - last > 12 * 3600:
    try:
        subprocess.run(
            ["osascript", "-e",
             'display notification "{}" with title "Claude Code login"'.format(
                 msgs[0].replace('"', "'")[:180])],
            capture_output=True, timeout=5)
        open(STAMP, "w").close()
    except Exception:
        pass

print(json.dumps({"continue": True, "systemMessage": "  ".join(msgs)}))
PY
exit 0
