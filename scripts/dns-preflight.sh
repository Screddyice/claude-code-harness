#!/usr/bin/env bash
# dns-preflight.sh — what breaks if I move this domain's DNS right now?
#
#   ./dns-preflight.sh <domain> [target-nameserver-or-ip ...]
#
# WHY THIS EXISTS
#   On 2026-08-14 reddy2help.org was moved from Squarespace DNS to GoDaddy. The
#   runbook checked the website records and the mail records and still took the
#   domain completely offline, mail included, because nothing asked whether the
#   delegation was SIGNED.
#
#   It was. .org published a DS record and resolvers were validating. The new
#   provider's zone served no DNSKEY. A registrar disables DNSSEC to permit a
#   nameserver change, but it stops signing IMMEDIATELY while the DS leaves the
#   registry on its own TTL. In that window the registry advertises "this zone is
#   signed" and the nameservers answer unsigned, so every validating resolver
#   refuses the answer. Measured within a minute of the change: SERVFAIL on
#   1.1.1.1, 8.8.8.8 and 9.9.9.9.
#
#   The same run also found the destination zone had been created with NO MX, SPF
#   or DKIM at all. Switching before noticing would have killed Google Workspace
#   mail on a domain that asks people for donations.
#
#   Both are one dig away. This is that dig, plus the rest of the pre-flight, so
#   the outage window is a scheduling decision instead of a discovery.
#
# EXIT
#   0  safe to proceed
#   1  blocking finding (read it before scheduling anything)
#
# Read-only. Makes no changes to anything.
set -uo pipefail

DOMAIN="${1:-}"
shift 2>/dev/null || true
TARGETS=("$@")

if [ -z "$DOMAIN" ]; then
  echo "usage: dns-preflight.sh <domain> [target-nameserver-or-ip ...]" >&2
  echo "  e.g. dns-preflight.sh example.org ns21.domaincontrol.com ns22.domaincontrol.com" >&2
  exit 2
fi

R="@1.1.1.1"
fail=0
warn=0

echo "→ DNS cutover pre-flight for $DOMAIN"
echo

# ── 1. DNSSEC ───────────────────────────────────────────────────────────
# The check whose absence caused the outage. Everything else is recoverable in
# minutes; this one takes the whole domain down until a registry TTL expires.
echo "── DNSSEC ──"
DS="$(dig +short DS "$DOMAIN" $R 2>/dev/null | head -3)"
if [ -n "$DS" ]; then
  echo "  ✗ SIGNED — the registry publishes a DS record:"
  echo "$DS" | sed 's/^/      /'
  AD="$(dig "$DOMAIN" A $R +dnssec 2>/dev/null | grep -c 'flags:.* ad')"
  [ "$AD" != "0" ] && echo "      resolvers are actively validating (ad flag set)"
  echo
  echo "    Moving nameservers means the registrar disables DNSSEC first. It stops"
  echo "    signing immediately, but the DS leaves the registry on its TTL, and in"
  echo "    that gap the domain does not resolve AT ALL — website and mail both."
  echo "    Schedule this when an outage of roughly that length is acceptable."
  fail=1
else
  echo "  ✓ unsigned — no DS at the registry, no DNSSEC outage window"
fi
echo

# ── 2. TTLs ─────────────────────────────────────────────────────────────
# Sizes the window above, and the ordinary propagation lag.
echo "── TTLs (how long stale answers persist) ──"
apex_ttl="$(dig "$DOMAIN" A $R 2>/dev/null | awk -v d="$DOMAIN." '$1==d && $4=="A"{print $2; exit}')"
ns_ttl="$(dig "$DOMAIN" NS $R 2>/dev/null | awk -v d="$DOMAIN." '$1==d && $4=="NS"{print $2; exit}')"
fmt_ttl() { [ -z "${1:-}" ] && { echo "unknown"; return; }; awk -v t="$1" 'BEGIN{printf "%ss (%.1fh)", t, t/3600}'; }
echo "  apex A : $(fmt_ttl "$apex_ttl")"
echo "  NS     : $(fmt_ttl "$ns_ttl")"
if [ -n "$apex_ttl" ] && [ "$apex_ttl" -gt 3600 ] 2>/dev/null; then
  echo "  ! apex TTL is over an hour. Lower it well before the cutover if you want a"
  echo "    short window; resolvers that already cached will hold the old answer."
  warn=1
fi
echo

# ── 3. Mail ─────────────────────────────────────────────────────────────
# Inventory to check the destination against. DKIM gets fingerprinted rather
# than merely noted, because a key that is present but mangled looks healthy and
# silently fails authentication.
echo "── Mail records to carry over ──"
MX="$(dig +short MX "$DOMAIN" $R 2>/dev/null | sort | tr '\n' ' ')"
SPF="$(dig +short TXT "$DOMAIN" $R 2>/dev/null | tr -d '"' | grep -i '^v=spf1' || true)"
DMARC="$(dig +short TXT "_dmarc.$DOMAIN" $R 2>/dev/null | tr -d '"' | grep -i '^v=DMARC1' || true)"

[ -n "$MX" ]  && echo "  MX    : $MX"  || echo "  MX    : (none — domain does not receive mail)"
[ -n "$SPF" ] && echo "  SPF   : $SPF" || echo "  SPF   : (none)"
[ -n "$DMARC" ] && echo "  DMARC : $DMARC" || echo "  DMARC : (none)"

# DKIM: try the common selectors rather than guessing one.
DKIM_SEL=""; DKIM_FP=""
for sel in google default selector1 selector2 s1 s2 k1 mail dkim; do
  raw="$(dig +short TXT "${sel}._domainkey.$DOMAIN" $R 2>/dev/null)"
  [ -z "$raw" ] && continue
  DKIM_SEL="$sel"
  DKIM_FP="$(DKIM_RAW="$raw" python3 - <<'PY' 2>/dev/null
import base64, os, re, subprocess
# A key over 255 chars is published split across adjacent quoted strings. The
# split is an encoding artifact, not a delimiter: concatenate, never join.
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
  break
done

if [ -n "$DKIM_SEL" ]; then
  if [ -n "$DKIM_FP" ]; then
    echo "  DKIM  : selector '$DKIM_SEL', key sha256 ${DKIM_FP:0:16}…"
    echo "          record this — dns-postflight.sh compares against it to prove the"
    echo "          key survived the move byte-for-byte"
  else
    echo "  ✗ DKIM  : selector '$DKIM_SEL' present but the key does not parse"
    echo "          it is already broken; fix before moving anything"
    fail=1
  fi
else
  echo "  DKIM  : (none found on common selectors)"
fi
echo

# ── 4. Destination zone ─────────────────────────────────────────────────
# Query the target nameservers directly. A zone is inert until delegated, so it
# can and should be built and checked BEFORE the switch.
if [ ${#TARGETS[@]} -gt 0 ]; then
  echo "── Destination zone (queried directly, before any cutover) ──"
  for t in "${TARGETS[@]}"; do
    echo "  via $t"
    t_a="$(dig +short A "$DOMAIN" "@$t" +time=5 +tries=1 2>/dev/null | head -2 | tr '\n' ' ')"
    if [ -z "$t_a" ]; then
      echo "    ✗ no answer — the zone does not exist there, or $t is not authoritative"
      fail=1; continue
    fi
    echo "    A     : $t_a"
    t_mx="$(dig +short MX "$DOMAIN" "@$t" +time=5 +tries=1 2>/dev/null | sort | tr '\n' ' ')"
    t_spf="$(dig +short TXT "$DOMAIN" "@$t" +time=5 +tries=1 2>/dev/null | tr -d '"' | grep -i '^v=spf1' || true)"

    if [ -n "$MX" ] && [ -z "$t_mx" ]; then
      echo "    ✗ MX    : MISSING at the destination (source has: $MX)"
      echo "            cutting over now takes inbound mail down instantly"
      fail=1
    elif [ -n "$t_mx" ]; then
      [ "$t_mx" = "$MX" ] && echo "    ✓ MX    : matches" || echo "    ! MX    : DIFFERS — src[$MX] dst[$t_mx]"
      [ "$t_mx" = "$MX" ] || warn=1
    fi

    if [ -n "$SPF" ] && [ -z "$t_spf" ]; then
      echo "    ✗ SPF   : MISSING at the destination"; fail=1
    elif [ -n "$t_spf" ]; then
      [ "$t_spf" = "$SPF" ] && echo "    ✓ SPF   : matches" || echo "    ! SPF   : DIFFERS"
      [ "$t_spf" = "$SPF" ] || warn=1
    fi

    if [ -n "$DKIM_SEL" ]; then
      t_dkim="$(dig +short TXT "${DKIM_SEL}._domainkey.$DOMAIN" "@$t" +time=5 +tries=1 2>/dev/null)"
      if [ -z "$t_dkim" ]; then
        echo "    ✗ DKIM  : MISSING at the destination (selector '$DKIM_SEL')"
        echo "            mail would keep sending and silently fail authentication"
        fail=1
      else
        t_fp="$(DKIM_RAW="$t_dkim" python3 - <<'PY' 2>/dev/null
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
        if [ "$t_fp" = "$DKIM_FP" ] && [ -n "$t_fp" ]; then
          echo "    ✓ DKIM  : key matches the source byte-for-byte"
        else
          echo "    ✗ DKIM  : key at destination does NOT match the source"
          echo "            almost always the split TXT strings rejoined wrong"
          fail=1
        fi
      fi
    fi

    # DNSSEC at the destination decides whether the DS can stay.
    t_key="$(dig +short DNSKEY "$DOMAIN" "@$t" +time=5 +tries=1 2>/dev/null | head -1)"
    if [ -n "$DS" ] && [ -z "$t_key" ]; then
      echo "    ✗ DNSSEC: destination serves NO DNSKEY while a DS is published"
      echo "            this exact pair is what makes resolvers SERVFAIL"
      fail=1
    fi
  done
  echo
else
  echo "── Destination zone ──"
  echo "  (skipped — pass the target nameservers to check the zone before cutting over)"
  echo "  e.g. dns-preflight.sh $DOMAIN ns21.domaincontrol.com"
  warn=1
  echo
fi

# ── 5. Registrar ────────────────────────────────────────────────────────
echo "── Registrar ──"
W="$(whois "$DOMAIN" 2>/dev/null || true)"
reg="$(printf '%s' "$W" | grep -iE '^\s*Registrar:' | head -1 | cut -d: -f2- | sed 's/^ *//')"
created="$(printf '%s' "$W" | grep -iE '^\s*Creation Date:' | head -1 | awk '{print $NF}' | cut -dT -f1)"
locked="$(printf '%s' "$W" | grep -icE 'clientTransferProhibited')"
echo "  registrar : ${reg:-unknown}"
echo "  created   : ${created:-unknown}"
if [ "${locked:-0}" != "0" ]; then
  echo "  ! clientTransferProhibited is set — registrar transfers are blocked."
  echo "    Nameserver changes are a DIFFERENT operation and are still allowed."
  if [ -n "$created" ]; then
    python3 -c "
from datetime import datetime, timedelta, timezone
try:
    c = datetime.fromisoformat('$created').replace(tzinfo=timezone.utc)
    u = c + timedelta(days=60)
    d = (u - datetime.now(timezone.utc)).days
    print(f'    ICANN 60-day lock from registration lifts ~{u.date()}' + (f' ({d} days away)' if d > 0 else ' (elapsed)'))
except Exception: pass
" 2>/dev/null
  fi
fi
echo

# ── verdict ─────────────────────────────────────────────────────────────
if [ "$fail" != "0" ]; then
  echo "✗ BLOCKING findings above. Do not cut over until they are resolved or"
  echo "  deliberately accepted with a scheduled window." >&2
  exit 1
fi
[ "$warn" != "0" ] && echo "! proceed with the warnings above in mind."
cat <<EOF
✓ pre-flight clean.

  Order that keeps mail alive: BUILD THE DESTINATION ZONE FIRST, SWITCH LAST.
  A zone is inert until the nameservers point at it, so it can be built and
  verified with zero risk. Switching first and building after is an outage.

  After the switch, run:
    dns-postflight.sh $DOMAIN ${DKIM_FP:+--dkim-fingerprint $DKIM_FP}
EOF
