#!/usr/bin/env bash
# oauth-expiry-check.sh — what actually drives Claude Code's
# "Your login expires in N day(s) · run /login to renew" banner.
#
# The banner reads ONLY refreshTokenExpiresAt from the macOS keychain item
# "Claude Code-credentials". It fires when that is <3 days out, and the
# spinner-tip variant when <24h. daysLeft is Math.ceil(), so ANY remaining
# fraction of a day renders as "1 day" — which is why a refresh token stuck
# near its expiry says "1 day" every single day.
#
# The 8-hour accessToken rotating is normal and is NOT what the banner reads.
#
# Usage: oauth-expiry-check.sh [--log]   (--log appends a JSON line to
#        ~/.claude/oauth-expiry.log so a regression is caught with a timestamp)

set -uo pipefail

MODE="${1:-}" LOG_PATH="${HOME}/.claude/oauth-expiry.log" python3 - <<'PY'
import os, sys, json, math, subprocess, datetime

try:
    blob = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True, check=True).stdout
except subprocess.CalledProcessError:
    sys.exit("could not read keychain item 'Claude Code-credentials'")

try:
    o = json.loads(blob)
except ValueError as e:
    sys.exit(f"credential blob is not JSON: {e}")
o = o.get("claudeAiOauth", o)

now = datetime.datetime.now(datetime.timezone.utc)

def at(key):
    v = o.get(key)
    if not isinstance(v, (int, float)):
        return None, None
    t = datetime.datetime.fromtimestamp(v / 1000, datetime.timezone.utc)
    return t, (t - now).total_seconds()

acc_t, acc_s = at("expiresAt")
ref_t, ref_s = at("refreshTokenExpiresAt")

if ref_s is None:
    days_left, verdict = None, "no refreshTokenExpiresAt stored -> banner cannot fire"
elif ref_s <= 0:
    days_left, verdict = 0, "REFRESH TOKEN EXPIRED -> run /login"
elif ref_s > 3 * 86400:
    days_left, verdict = None, "healthy -> banner should NOT appear"
else:
    days_left = math.ceil(ref_s / 86400)
    plural = "" if days_left == 1 else "s"
    verdict = f'BANNER ACTIVE: "Your login expires in {days_left} day{plural}"'

def fmt(t, s, label):
    if t is None:
        return "  {:<22} (not set)".format(label)
    stamp = t.isoformat(timespec="seconds")
    return "  {:<22} {}   ({:+.2f} days / {:+.1f} h)".format(label, stamp, s / 86400, s / 3600)

if os.environ.get("MODE") == "--log":
    with open(os.environ["LOG_PATH"], "a") as f:
        f.write(json.dumps({
            "ts": now.isoformat(timespec="seconds"),
            "accessExpiresAt": o.get("expiresAt"),
            "refreshTokenExpiresAt": o.get("refreshTokenExpiresAt"),
            "refreshDaysLeft": round(ref_s / 86400, 3) if ref_s is not None else None,
            "subscriptionType": o.get("subscriptionType"),
        }) + "\n")

print("Claude Code login state")
print(fmt(acc_t, acc_s, "access token"))
print(fmt(ref_t, ref_s, "refresh token"))
print("  {:<22} {}  ({})".format("subscription", o.get("subscriptionType"), o.get("rateLimitTier")))
print()
print("  => " + verdict)
if days_left is not None and ref_s and ref_s > 0:
    print("     Only a real /login mints a new refresh token. Ordinary 8h")
    print("     access-token refreshes do NOT extend this window.")
PY
