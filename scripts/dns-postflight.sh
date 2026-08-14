#!/usr/bin/env bash
# dns-postflight.sh — did the cutover actually land, and did mail survive?
#
#   ./dns-postflight.sh <domain> [options]
#
#     --expect-ip <ip>            the origin the domain should now resolve to
#     --dkim-fingerprint <sha256> value printed by dns-preflight.sh before the move
#     --acme-host <ssh-alias>     host running the TLS terminator, to clear its backoff
#     --acme-service <name>       systemd unit on that host (default: caddy)
#     --wait <seconds>            how long to wait for propagation (default: 900)
#
# WHY THIS EXISTS
#   Two things went wrong AFTER the reddy2help.org cutover on 2026-08-14, and
#   neither is visible from the registrar's "nameservers updated" confirmation.
#
#   1. Propagation is staged, not atomic. The NS change reached the registry
#      before the DS removal did, so for a while the registry delegated to an
#      unsigned zone while still advertising DNSSEC. Every validating resolver
#      returned SERVFAIL. Watching one resolver, or worse the registrar's own UI,
#      shows none of this.
#
#   2. The ACME client does not know DNS changed. Caddy had been failing to get a
#      certificate for three days because the domain still pointed elsewhere. By
#      cutover it was on attempt 33 with a SIX HOUR backoff and had fallen through
#      to Let's Encrypt STAGING, whose certificates browsers reject. DNS was
#      perfect, mail was perfect, and the site served nothing. A restart fixed it
#      in ten seconds — but only because someone thought to look.
#
#   So this polls every major validating resolver rather than one, re-proves the
#   DKIM key rather than its presence, and treats "clear the ACME backoff and
#   confirm the cert is real" as a required step rather than an afterthought.
#
# EXIT
#   0  cutover verified
#   1  something is still wrong (details above the verdict)
set -uo pipefail

DOMAIN="${1:-}"; shift 2>/dev/null || true
EXPECT_IP=""; DKIM_FP=""; ACME_HOST=""; ACME_SVC="caddy"; WAIT=900

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-ip) EXPECT_IP="${2:-}"; shift 2 ;;
    --dkim-fingerprint) DKIM_FP="${2:-}"; shift 2 ;;
    --acme-host) ACME_HOST="${2:-}"; shift 2 ;;
    --acme-service) ACME_SVC="${2:-}"; shift 2 ;;
    --wait) WAIT="${2:-900}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -z "$DOMAIN" ] && { echo "usage: dns-postflight.sh <domain> [options]" >&2; exit 2; }

RESOLVERS=(1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222)
fail=0

echo "→ DNS cutover post-flight for $DOMAIN"
echo

# ── 1. Propagation across validating resolvers ──────────────────────────
# One resolver is not evidence. They cache independently and the DS and NS
# changes land at different times.
echo "── Propagation ──"
deadline=$(( $(date +%s) + WAIT ))
while :; do
  ok=0; line=""
  for r in "${RESOLVERS[@]}"; do
    st="$(dig "$DOMAIN" A "@$r" +time=4 +tries=1 2>/dev/null | grep -oE 'status: [A-Z]+' | head -1 | awk '{print $2}')"
    [ "$st" = "NOERROR" ] && ok=$((ok+1))
    line="$line $r=${st:-timeout}"
  done
  [ "$ok" -eq "${#RESOLVERS[@]}" ] && { echo "  ✓ all resolvers NOERROR:$line"; break; }
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "  ✗ still not fully propagated after ${WAIT}s:$line"
    echo
    echo "    SERVFAIL on some resolvers usually means a stale DS is still published"
    echo "    while the new nameservers answer unsigned. Check:"
    echo "      dig +short DS $DOMAIN"
    echo "    If a DS is present and the new provider does not sign, the registrar"
    echo "    must remove it. Resolution recovers on the record's TTL, not sooner."
    fail=1; break
  fi
  echo "  … waiting:$line"
  sleep 30
done
echo

# ── 2. Where it points, and who serves it ───────────────────────────────
echo "── Delegation ──"
NS="$(dig +short NS "$DOMAIN" @1.1.1.1 2>/dev/null | sort | tr '\n' ' ')"
IP="$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | head -1)"
echo "  NS : ${NS:-none}"
echo "  A  : ${IP:-none}"
if [ -n "$EXPECT_IP" ]; then
  if [ "$IP" = "$EXPECT_IP" ]; then
    echo "  ✓ resolves to the expected origin"
  else
    echo "  ✗ expected $EXPECT_IP"; fail=1
  fi
fi
echo

# ── 3. Mail ─────────────────────────────────────────────────────────────
# Presence is not enough. A DKIM key that is present but rejoined wrong is
# well-formed and cryptographically junk: mail keeps sending and silently fails
# authentication, which nobody notices until replies stop arriving.
echo "── Mail ──"
MX="$(dig +short MX "$DOMAIN" @1.1.1.1 2>/dev/null | tr '\n' ' ')"
SPF="$(dig +short TXT "$DOMAIN" @1.1.1.1 2>/dev/null | tr -d '"' | grep -i '^v=spf1' || true)"
[ -n "$MX" ]  && echo "  ✓ MX  : $MX"  || { echo "  ✗ MX  : MISSING — inbound mail is down"; fail=1; }
[ -n "$SPF" ] && echo "  ✓ SPF : present" || { echo "  ✗ SPF : MISSING"; fail=1; }

if [ -n "$DKIM_FP" ]; then
  found=0
  for sel in google default selector1 selector2 s1 s2 k1 mail dkim; do
    raw="$(dig +short TXT "${sel}._domainkey.$DOMAIN" @1.1.1.1 2>/dev/null)"
    [ -z "$raw" ] && continue
    now_fp="$(DKIM_RAW="$raw" python3 - <<'PY' 2>/dev/null
import base64, os, re, subprocess
joined = "".join(re.findall(r'"([^"]*)"', os.environ["DKIM_RAW"])) or os.environ["DKIM_RAW"].strip()
m = re.search(r'p=([A-Za-z0-9+/=]+)', joined)
if not m: raise SystemExit
try: der = base64.b64decode(m.group(1), validate=True)
except Exception: raise SystemExit
pub = subprocess.run(["openssl","rsa","-pubin","-inform","DER","-outform","DER","-pubout"],
                     input=der, capture_output=True)
if pub.returncode: raise SystemExit
print(subprocess.run(["openssl","dgst","-sha256"], input=pub.stdout,
                     capture_output=True).stdout.decode().split()[-1])
PY
)"
    found=1
    if [ "$now_fp" = "$DKIM_FP" ]; then
      echo "  ✓ DKIM: selector '$sel' matches the pre-move key byte-for-byte"
    else
      echo "  ✗ DKIM: selector '$sel' does NOT match the pre-move key"
      echo "          expected ${DKIM_FP:0:16}… got ${now_fp:0:16}…"
      echo "          almost always the split TXT strings rejoined wrong"
      fail=1
    fi
    break
  done
  [ "$found" = "0" ] && { echo "  ✗ DKIM: no key found at the destination"; fail=1; }
else
  echo "  ! DKIM: no pre-move fingerprint given, cannot prove the key is unchanged"
  echo "          pass --dkim-fingerprint from the pre-flight next time"
fi
echo

# ── 4. TLS — the step everyone forgets ──────────────────────────────────
echo "── TLS ──"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/" 2>/dev/null)"

if [ "$code" != "200" ] && [ -n "$ACME_HOST" ]; then
  echo "  HTTPS returned ${code:-000} — clearing the ACME backoff on $ACME_HOST"
  echo "    (an ACME client cannot observe that DNS changed; after repeated failures"
  echo "     it backs off for hours and may fall through to a staging endpoint)"
  ssh -o ConnectTimeout=15 "$ACME_HOST" "systemctl restart $ACME_SVC" 2>/dev/null \
    || echo "  ! could not restart $ACME_SVC on $ACME_HOST"
  for i in 1 2 3 4 5 6; do
    sleep 10
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null)"
    echo "    +$((i*10))s HTTPS: ${code:-000}"
    [ "$code" = "200" ] && break
  done
fi

if [ "$code" = "200" ]; then
  echo "  ✓ HTTPS 200"
else
  echo "  ✗ HTTPS ${code:-000}"
  [ -z "$ACME_HOST" ] && echo "    pass --acme-host <ssh-alias> to clear a stuck ACME backoff automatically"
  fail=1
fi

# A staging certificate is the failure that looks like success in curl but is
# rejected by every browser.
issuer="$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
          | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
if [ -n "$issuer" ]; then
  if printf '%s' "$issuer" | grep -qiE 'staging|fake|test'; then
    echo "  ✗ certificate is from a STAGING issuer — browsers will reject it"
    echo "    issuer: $issuer"
    fail=1
  else
    echo "  ✓ issuer: $issuer"
    exp="$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
           | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    [ -n "$exp" ] && echo "    valid until $exp"
  fi
fi

# Serving the real site, not the old host's placeholder. A parking page answers
# 200 too, which is how a retired host once passed a status-code check.
title="$(curl -s --max-time 10 "https://$DOMAIN/" 2>/dev/null | grep -oE '<title>[^<]*</title>' | head -1)"
[ -n "$title" ] && echo "  serving: $title"
echo

# ── verdict ─────────────────────────────────────────────────────────────
if [ "$fail" != "0" ]; then
  echo "✗ cutover NOT verified — see the failures above." >&2
  exit 1
fi
cat <<EOF
✓ cutover verified: propagated, mail intact, TLS real.

  Still worth checking by hand:
    - if DNSSEC was disabled to permit this move, restoring it is a separate
      operation with its own ordering rule: sign the zone first, publish the DS
      second. Publishing a DS before the zone is signed repeats the outage.
    - send a test mail both directions; DNS being right is necessary, not sufficient.
EOF
