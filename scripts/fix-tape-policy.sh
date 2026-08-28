#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# fix-tape-policy.sh (v2) — سیاست تأیید Tape را با سیاست واقعیِ مستقر
# هم‌تراز می‌کند.
#
# چرا این اصلاح لازم بود
# ──────────────────────
# قراردادها با سیاست OR('org1MSP.member', ... ,'org8MSP.member') کامیت
# می‌شوند (CC_POLICY در deploy_functions.sh) — یعنی **یک امضا** برای معتبر
# شدن تراکنش کافی است. اما نسخهٔ اول این اسکریپت و install-test-tools.sh
# برای Tape یک rego با `count(input) >= 5` می‌نوشتند.
#
# نتیجه: Tape در هر تراکنش چهار امضای اضافه جمع می‌کرد که شبکه هرگز
# نخواسته بود. دو پیامد داشت:
#   ۱) تأخیر و گذردهی گزارش‌شدهٔ Tape مصنوعاً بدتر از واقعیت شبکه بود
#   ۲) مقایسهٔ Tape با Caliper بی‌اعتبار می‌شد، چون Caliper با یک peer
#      به‌ازای هر سازمان و مطابق سیاست واقعی فقط یک امضا می‌گیرد —
#      عملاً دو ابزار دو سیاست متفاوت را می‌سنجیدند، نه یک شبکهٔ یکسان.
#
# حالا دو فایل سیاست جدا ساخته می‌شود:
#   endorsement-any.rego       count>=1  ← مطابق استقرار (پیش‌فرض)
#   endorsement-majority.rego  count>=5  ← فرضیِ سخت‌گیرانه، برای مقایسهٔ
#                                          عمدیِ هزینهٔ سیاست
#
# استفاده:
#   ./fix-tape-policy.sh              # همه کانفیگ‌ها → سیاست any
#   ./fix-tape-policy.sh majority     # همه کانفیگ‌ها → سیاست majority
#
# اجرای چندباره بی‌ضرر است.
# ══════════════════════════════════════════════════════════════════════
set -e

ROOT_DIR="${ROOT_DIR:-/root/health-network}"
TAPE_DIR="${TAPE_CONFIG_DIR:-$ROOT_DIR/test-tools/tape-configs}"
MODE="${1:-any}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

case "$MODE" in
    any|majority) ;;
    *) echo -e "${RED}حالت نامعتبر: $MODE (any یا majority)${NC}"; exit 1 ;;
esac

mkdir -p "$TAPE_DIR"

# ── ۱) هر دو فایل سیاست ──
cat > "${TAPE_DIR}/endorsement-any.rego" << 'REGO_EOF'
package tape

default allow = false

# مطابق سیاست مستقر روی chaincode:
#   OR('org1MSP.member', ... ,'org8MSP.member')
# یک امضا کافی است.
allow {
    count(input) >= 1
}
REGO_EOF

cat > "${TAPE_DIR}/endorsement-majority.rego" << 'REGO_EOF'
package tape

default allow = false

# سیاست سخت‌گیرانهٔ فرضی: MAJORITY از ۸ سازمان.
# روی این شبکه مستقر نیست — فقط برای سنجش هزینهٔ سیاست سخت‌گیرانه‌تر.
# نتایجی که با این سیاست گرفته می‌شوند باید صریحاً «فرضی» برچسب بخورند.
allow {
    count(input) >= 5
}
REGO_EOF

ACTIVE="${TAPE_DIR}/endorsement-${MODE}.rego"

# سازگاری با هر کانفیگ یا کدی که هنوز نام قدیمی را می‌شناسد
cp "$ACTIVE" "${TAPE_DIR}/majority.rego"

echo -e "${GREEN}✓${NC} فایل‌های سیاست ساخته شدند در $TAPE_DIR"
echo -e "  سیاست فعال: ${YELLOW}${MODE}${NC} → $ACTIVE"

# ── ۲) بازنشانی policyFile در همهٔ کانفیگ‌های موجود ──
shopt -s nullglob
CONFIGS=("${TAPE_DIR}"/config*.yaml)
shopt -u nullglob

if [ ${#CONFIGS[@]} -eq 0 ]; then
    echo -e "${YELLOW}⚠${NC} هیچ config*.yaml یافت نشد — اول install-test-tools.sh را اجرا کنید"
else
    PATCHED=0
    for f in "${CONFIGS[@]}"; do
        if grep -q "^policyFile:" "$f"; then
            sed -i "s|^policyFile:.*|policyFile: ${ACTIVE}|" "$f"
        else
            # اگر اصلاً فیلد نداشت، پیش از خط channel درج می‌شود
            sed -i "0,/^channel:/s|^channel:|policyFile: ${ACTIVE}\nchannel:|" "$f"
        fi
        PATCHED=$((PATCHED+1))
    done
    echo -e "${GREEN}✓${NC} ${PATCHED} کانفیگ به سیاست ${MODE} بازنشانی شد"
fi

# ── SAMPLE محاسبهٔ یکجا ──
# اولین کانفیگ موجود، برای نمونهٔ پایانی و شمارش endorser. یک بار
# و مستقل از حالت سیاست — نسخهٔ قبلی آن را داخل شاخهٔ majority
# تعریف می‌کرد، پس در حالت پیش‌فرض بلوک نمونه خالی چاپ می‌شد.
SAMPLE=""
for _f in "${TAPE_DIR}"/config-*.yaml; do
    [ -f "$_f" ] && { SAMPLE="$_f"; break; }
done
SAMPLE_CH="$(basename "${SAMPLE:-config-none.yaml}" .yaml | sed 's/^config-//')"

# ── ۳) هشدار دربارهٔ تعداد endorser ──
# سیاست majority با کمتر از ۵ endorser هرگز برآورده نمی‌شود.
if [ "$MODE" = "majority" ]; then
    if [ -f "$SAMPLE" ]; then
        N=$(grep -c "addr: peer0" "$SAMPLE" || true)
        # یکی از تطابق‌ها مربوط به committer است
        E=$((N - 1))
        if [ "$E" -lt 5 ]; then
            echo -e "${RED}✗${NC} کانفیگ‌ها فقط ${E} endorser دارند ولی سیاست majority به ۵ نیاز دارد"
            echo -e "  Tape با این ترکیب هیچ تراکنشی را معتبر نمی‌شمارد."
        fi
    fi
fi

# ── ۴) هم‌ترازی سرور ──
# روتر /api/bench فایل سیاست را خودش می‌سازد و انتخاب می‌کند، ولی مسیر
# قدیمیِ /api/test/execute نام فایل را در index.js ثابت دارد.
INDEX="$ROOT_DIR/server/index.js"
if [ -f "$INDEX" ] && grep -q "majority.rego" "$INDEX"; then
    echo ""
    echo -e "${YELLOW}⚠${NC} server/index.js هنوز به majority.rego اشاره می‌کند."
    echo -e "  اجرا کنید: ${GREEN}bash $ROOT_DIR/server/patch-index.sh${NC}"
    echo -e "  (نسخهٔ ۵ آن را به endorsement-any.rego تغییر می‌دهد)"
fi

echo ""
echo "نمونه ($SAMPLE_CH):"
[ -n "${SAMPLE:-}" ] && grep -E "^policyFile:|^channel:|^chaincode:" "$SAMPLE" 2>/dev/null || true
echo ""
echo "اجرای تست:  $ROOT_DIR/test-tools/run-tape.sh $SAMPLE_CH"
echo "یا از رابط وب: صفحهٔ Benchmark ← تب Tape (سیاست از همان‌جا انتخاب می‌شود)"
