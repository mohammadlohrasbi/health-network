#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# fix-tape-tls.sh — مسیر گواهی TLS را در کانفیگ‌های Tape پر می‌کند.
#
# کانفیگ‌های ایستای Tape را install-test-tools.sh می‌سازد و تا وقتی شبکه
# plaintext بود، `tls_ca_cert: ""` در آنها درست بود. با TLS روشن، Tape
# بدون گواهی وصل نمی‌شود:
#
#   fail to load TLS CA Cert ...: no such file or directory
#
# این اسکریپت فقط همان فیلد را پر می‌کند — بدون نصب دوباره ابزارها، که
# چند دقیقه طول می‌کشد و دلیلی ندارد.
#
# با NETWORK_TLS=false در .env، فیلدها را خالی می‌کند تا شبکه plaintext هم
# کار کند.
#
# استفاده:
#   ./fix-tape-tls.sh
#   DRY_RUN=1 ./fix-tape-tls.sh
# ══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DIR="${ROOT_DIR:-/root/health-network}"
TAPE_DIR="${TAPE_CONFIG_DIR:-$ROOT_DIR/test-tools/tape-configs}"
CRYPTO="${CRYPTO_BASE:-$ROOT_DIR/config/crypto-config}"
DRY_RUN="${DRY_RUN:-0}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
bad()  { echo -e "  ${RED}✗${NC} $*"; }

echo ""
echo "گواهی TLS در کانفیگ‌های Tape"
[ "$DRY_RUN" = "1" ] && warn "DRY_RUN — چیزی نوشته نمی‌شود"
echo "────────────────────────────────────────────"

[ -d "$TAPE_DIR" ] || { bad "$TAPE_DIR نیست — اول install-test-tools.sh"; exit 1; }

TLS_ON="$(grep -oE '^NETWORK_TLS[[:space:]]*=[[:space:]]*\S+' "$ROOT_DIR/config/.env" 2>/dev/null \
    | tr -d ' ' | cut -d= -f2)"

if [ "$TLS_ON" = "true" ]; then
    ORD_TLS="$(find "$CRYPTO/ordererOrganizations" -path "*msp/tlscacerts/*.pem" 2>/dev/null | head -1)"
    [ -n "$ORD_TLS" ] || { bad "گواهی سازمان اوردرر پیدا نشد در $CRYPTO"; exit 1; }
    ok "TLS روشن — گواهی اوردرر: ${ORD_TLS#$ROOT_DIR/}"
else
    ORD_TLS=""
    warn "NETWORK_TLS در .env روشن نیست — فیلدها خالی می‌شوند"
fi

# گواهی هر سازمان، از روی دیسک
declare -A ORG_TLS
for i in 1 2 3 4 5 6 7 8; do
    if [ "$TLS_ON" = "true" ]; then
        ORG_TLS[org$i]="$(find "$CRYPTO/peerOrganizations/org$i.example.com" \
            -path "*msp/tlscacerts/*.pem" 2>/dev/null | head -1)"
    else
        ORG_TLS[org$i]=""
    fi
done

N=0
for f in "$TAPE_DIR"/config-*.yaml; do
    [ -f "$f" ] || continue
    [ "$DRY_RUN" = "1" ] && { echo "  → $(basename "$f")"; N=$((N+1)); continue; }

    # هر خط tls_ca_cert بر اساس addr خط قبلی‌اش پر می‌شود. اوردرر با
    # آدرس orderer* شناخته می‌شود، بقیه با شماره سازمان.
    ORD_TLS="$ORD_TLS" \
    O1="${ORG_TLS[org1]}" O2="${ORG_TLS[org2]}" O3="${ORG_TLS[org3]}" O4="${ORG_TLS[org4]}" \
    O5="${ORG_TLS[org5]}" O6="${ORG_TLS[org6]}" O7="${ORG_TLS[org7]}" O8="${ORG_TLS[org8]}" \
    python3 - "$f" <<'PYEOF'
import os, re, sys
path = sys.argv[1]
lines = open(path).read().split('\n')
orgs = {('org%d' % i): os.environ.get('O%d' % i, '') for i in range(1, 9)}
ordc = os.environ.get('ORD_TLS', '')

last_addr = ''
out = []
for ln in lines:
    m = re.search(r'addr:\s*(\S+)', ln)
    if m:
        last_addr = m.group(1)
    if 'tls_ca_cert:' in ln:
        indent = ln[:len(ln) - len(ln.lstrip())]
        if last_addr.startswith('orderer'):
            val = ordc
        else:
            om = re.search(r'org(\d)', last_addr)
            val = orgs.get('org' + om.group(1), '') if om else ''
        ln = '%stls_ca_cert: "%s"' % (indent, val)
    out.append(ln)
open(path, 'w').write('\n'.join(out))
PYEOF
    N=$((N+1))
done

echo ""
if [ "$DRY_RUN" = "1" ]; then
    echo "$N کانفیگ به‌روز می‌شود."
    exit 0
fi
ok "$N کانفیگ به‌روز شد"

# ── تأیید: هر مسیر ناخالی باید روی دیسک باشد ──
SAMPLE="$TAPE_DIR/config-datachannel.yaml"
if [ -f "$SAMPLE" ]; then
    echo ""
    echo "نمونه (datachannel):"
    grep "tls_ca_cert" "$SAMPLE" | sort -u | sed 's/^/  /'
    MISSING=0
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -f "$p" ] || { bad "موجود نیست: $p"; MISSING=$((MISSING+1)); }
    done < <(grep -oE 'tls_ca_cert: "[^"]*"' "$SAMPLE" | sed 's/.*"\(.*\)"/\1/' | sort -u)
    [ "$MISSING" = "0" ] && ok "همه مسیرها روی دیسک موجودند"
fi

echo ""
echo "────────────────────────────────────────────"
echo "اجرای تست:  $ROOT_DIR/test-tools/run-tape.sh datachannel"
