#!/bin/bash
# ══════════════════════════════════════════════════════════════
# add-test-endpoint.sh (v3)
#
# نسخه قبلی این اسکریپت کد endpoint را به index.js تزریق می‌کرد؛
# اما index.js فعلی از قبل endpoint کامل /api/test/execute دارد
# (پیاده‌سازی spawn-محور که از نسخه تزریقی بهتر است). تزریق مجدد
# حذف شد. این اسکریپت حالا سه کار انجام می‌دهد:
#   1) راستی‌آزمایی: endpoint، وابستگی js-yaml، و نگاشت توابع واقعی
#   2) هماهنگ‌سازی مسیرها: symlink هایی که index.js انتظار دارد
#      (test-tools/caliper/{networks,benchmarks,workloads})
#   3) اعتبارسنجی syntax سرور
#   4) راستی‌آزمایی بنچمارک گسترده: روتر /api/bench، ماژول‌های آن،
#      دارایی‌های کالیپر، و هم‌ترازی سیاست تأیید Tape با سیاست مستقر
# اجرای چندباره بی‌ضرر است (idempotent).
# ══════════════════════════════════════════════════════════════
set -e

ROOT_DIR="${ROOT_DIR:-/root/health-network}"
SERVER_DIR="${ROOT_DIR}/server"
INDEX_FILE="${SERVER_DIR}/index.js"
TEST_DIR="${ROOT_DIR}/test-tools"
WORKSPACE="${TEST_DIR}/caliper-workspace"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; FAILED=1; }
FAILED=0

echo "=== راستی‌آزمایی زیرساخت تست سرور ==="

# ── ۱) endpoint موجود است؟ ──
if [ ! -f "$INDEX_FILE" ]; then
    fail "index.js یافت نشد: $INDEX_FILE"; exit 1
fi
if grep -qE "app\.post\(['\"]\/api\/test\/execute['\"]" "$INDEX_FILE"; then
    ok "endpoint /api/test/execute در index.js موجود است"
else
    fail "endpoint /api/test/execute در index.js نیست — index.js اصلاح‌شده را کپی کنید"
fi

# ── ۲) وابستگی js-yaml ──
if [ -d "${SERVER_DIR}/node_modules/js-yaml" ]; then
    ok "js-yaml نصب است"
else
    warn "js-yaml نصب نیست — در حال نصب..."
    (cd "$SERVER_DIR" && npm install js-yaml@4 --save)
    ok "js-yaml نصب شد"
fi

# ── ۳) نگاشت توابع واقعی (SCENARIO_FN اصلاح‌شده) ──
if grep -q "UpdateIoTStatus" "$INDEX_FILE"; then
    ok "SCENARIO_FN به توابع واقعی chaincode اشاره می‌کند"
else
    warn "SCENARIO_FN هنوز توابع قدیمی (RegisterDevice/CreateAsset...) دارد — patch-index.sh را اجرا کنید"
fi

# ── ۴) symlink های مسیر (سازگاری index.js با خروجی installer) ──
if [ -d "$WORKSPACE" ]; then
    ln -sfn "$WORKSPACE" "${TEST_DIR}/caliper"
    ln -sfn workload "${WORKSPACE}/workloads"
    ok "symlink ها: test-tools/caliper → caliper-workspace ، workloads → workload"
else
    warn "caliper-workspace هنوز ساخته نشده — اول install-test-tools.sh را اجرا کنید"
fi

# ── ۵) اعتبارسنجی syntax ──
if node --check "$INDEX_FILE" 2>/dev/null; then
    ok "syntax سرور سالم است"
else
    fail "خطای syntax در index.js"
fi
for f in fabric.js connection.js config.js; do
    if node --check "${SERVER_DIR}/${f}" 2>/dev/null; then
        ok "syntax ${f} سالم است"
    else
        fail "خطای syntax در ${f}"
    fi
done


echo ""
echo "=== راستی‌آزمایی بنچمارک گسترده ==="

# ── ۶) ماژول‌های بنچمارک ──
for f in bench-catalog.js bench-runner.js bench-routes.js; do
    if [ ! -f "${SERVER_DIR}/${f}" ]; then
        fail "${f} در server/ نیست — از بستهٔ تحویلی کپی کنید"
    elif node --check "${SERVER_DIR}/${f}" 2>/dev/null; then
        ok "syntax ${f} سالم است"
    else
        fail "خطای syntax در ${f}"
    fi
done

# ── ۷) روتر /api/bench متصل است؟ ──
if grep -q "app.use('/api/bench'" "$INDEX_FILE"; then
    ok "روتر /api/bench به index.js متصل است"
else
    warn "روتر /api/bench متصل نیست — اجرا کنید: bash ${SERVER_DIR}/patch-index.sh"
fi

# ── ۸) کاتالوگ بارگذاری می‌شود و با fabric.js هم‌خوان است؟ ──
if [ -f "${SERVER_DIR}/bench-catalog.js" ]; then
    DRIFT=$(cd "$SERVER_DIR" && node -e "
        const c = require('./bench-catalog');
        const d = c.assertCatalogInSync();
        const n = c.catalog().counts;
        console.log(d.length ? 'DRIFT:' + d.join(',') : 'OK:' + n.channels + ':' + n.targets);
    " 2>&1 || echo "ERR")
    case "$DRIFT" in
        OK:*) ok "کاتالوگ سالم است (${DRIFT#OK:} کانال:هدف) و با fabric.js هم‌خوان" ;;
        DRIFT:*) fail "نگاشت کانال در bench-catalog.js و fabric.js واگرا شده: ${DRIFT#DRIFT:}" ;;
        *) fail "کاتالوگ بارگذاری نشد: $DRIFT" ;;
    esac
fi

# ── ۹) دارایی‌های کالیپر ──
GENERIC="${WORKSPACE}/workload/generic-write.js"
if [ -f "$GENERIC" ]; then
    NAMED=$(find "${WORKSPACE}/workload" -maxdepth 1 -name '*.js' ! -name 'generic-*' \
            ! -name 'datachannel-*' 2>/dev/null | wc -l)
    ok "workload عمومی موجود است و ${NAMED} workload نام‌دار ساخته شده"
else
    warn "workload عمومی نیست — اجرا کنید: node ${ROOT_DIR}/scripts/gen-caliper-assets.js"
fi

# مسیری که index.js واقعاً می‌جوید
if [ -e "${TEST_DIR}/caliper/workloads/generic-write.js" ]; then
    ok "مسیر test-tools/caliper/workloads درست resolve می‌شود"
else
    warn "symlink های مسیر کالیپر ناقص‌اند — install-test-tools.sh را دوباره اجرا کنید"
fi

# ── ۱۰) سیاست تأیید Tape با سیاست مستقر هم‌تراز است؟ ──
# قراردادها با OR(...) کامیت می‌شوند (یک امضا کافی است). اگر Tape با
# count>=5 بسنجد، اعداد مصنوعاً بد می‌شوند و مقایسه با Caliper بی‌اعتبار.
TAPE_CFG="${TEST_DIR}/tape-configs"
if [ -f "${TAPE_CFG}/endorsement-any.rego" ]; then
    ok "فایل سیاست endorsement-any.rego موجود است"
else
    warn "endorsement-any.rego نیست — اجرا کنید: ${ROOT_DIR}/scripts/fix-tape-policy.sh"
fi

STALE=$(grep -l "count(input) >= 5" "${TAPE_CFG}/majority.rego" 2>/dev/null || true)
if [ -n "$STALE" ]; then
    fail "majority.rego هنوز count>=5 دارد ولی سیاست مستقر OR است (یک امضا)"
    echo -e "  اصلاح: ${GREEN}${ROOT_DIR}/scripts/fix-tape-policy.sh${NC}"
fi

if grep -q "majority.rego" "$INDEX_FILE" 2>/dev/null; then
    warn "index.js هنوز به majority.rego اشاره می‌کند — patch-index.sh (v5) را اجرا کنید"
fi

echo ""
[ "$FAILED" -eq 0 ] && echo -e "${GREEN}✅ همه بررسی‌ها موفق — سرور آماده اجرای تست‌هاست${NC}" \
                    || echo -e "${RED}برخی بررسی‌ها ناموفق — موارد بالا را برطرف کنید${NC}"
exit $FAILED
