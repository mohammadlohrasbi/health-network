#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# port-from-6g.sh — تبدیل یک نسخه از 6g-network-raft به شبکه سلامت
#
# چرا اسکریپت و نه چند دستور sed دستی؟ چون در پروژه 6G سه بار
# اصلاح دستی برگشت — یک بار چون network.sh فایل `run` را از
# heredoc خودش بازمی‌نوشت، و دو بار چون install.sh فایل را کپی
# نمی‌کرد. هر تغییری که دستی است، دفعه بعد فراموش می‌شود.
#
# ویژگی‌ها (مثل بقیه اسکریپت‌های این پروژه):
#   · DRY_RUN=1 برای دیدن بدون اعمال
#   · پشتیبان کامل پیش از هر تغییر
#   · اجرای دوباره امن (idempotent) — تشخیص می‌دهد قبلاً اجرا شده
#   · تأیید ساختاری پس از اعمال
#
# استفاده:
#   SRC=/root/6g-network-raft DST=/root/health-network \
#   PKG=/path/to/health-network-package ./port-from-6g.sh
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

SRC="${SRC:-/root/6g-network-raft}"
DST="${DST:-/root/health-network}"
PKG="${PKG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OLD_NET="6g-network"
NEW_NET="health-network"
DRY_RUN="${DRY_RUN:-0}"

log()   { echo "[$(date +'%H:%M:%S')] $*"; }
warn()  { echo "[$(date +'%H:%M:%S')] هشدار: $*" >&2; }
error() { echo "[$(date +'%H:%M:%S')] خطا: $*" >&2; exit 1; }
run()   { if [ "$DRY_RUN" = "1" ]; then echo "  [dry] $*"; else eval "$@"; fi; }

# ── بررسی پیش‌نیاز ────────────────────────────────────────
# مبدأ فقط برای انتقال اولیه لازم است. اگر مقصد از قبل شبکه سلامت
# باشد، اجرای دوباره فقط لایه دامنه را به‌روز می‌کند و به مبدأ
# کاری ندارد — این حالتی است که بعد از هر تغییر در قراردادها
# استفاده می‌شود.
if [ ! -f "$DST/reference/clinical.go" ]; then
  [ -d "$SRC" ] || error "مبدأ یافت نشد: $SRC (برای انتقال اولیه لازم است)"
  [ -f "$SRC/scripts/network.sh" ] || error "$SRC یک نسخه معتبر 6g-network-raft نیست"
fi
[ -f "$PKG/reference/clinical.go" ] || error "بسته سلامت در $PKG یافت نشد"
command -v node >/dev/null || error "node لازم است"
command -v go   >/dev/null || warn  "go یافت نشد — کامپایل قراردادها ممکن نخواهد بود"

# ── گام ۱: کپی ────────────────────────────────────────────
if [ -d "$DST" ]; then
  log "مقصد $DST از قبل وجود دارد"
  if [ -f "$DST/reference/clinical.go" ]; then
    log "به نظر می‌رسد انتقال قبلاً انجام شده — فقط لایه دامنه به‌روز می‌شود"
    ALREADY=1
  else
    error "$DST وجود دارد ولی شبکه سلامت نیست. پاکش کنید یا DST دیگری بدهید."
  fi
else
  ALREADY=0
  log "کپی $SRC → $DST"
  run "cp -a '$SRC' '$DST'"
  run "rm -rf '$DST/.git'"
fi

# ── پشتیبان ───────────────────────────────────────────────
BK="$DST/.port-backup-$(date +%Y%m%d-%H%M%S)"
if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$BK"
  for f in config/docker-compose.yml config/.env scripts/network.sh \
           scripts/bootstrap-secure.sh scripts/deploy_functions.sh \
           scripts/set-tls.sh scripts/setup-raft.sh server/bench-catalog.js \
           server/contract-fn-map.js server/fabric.js; do
    [ -f "$DST/$f" ] && { mkdir -p "$BK/$(dirname "$f")"; cp "$DST/$f" "$BK/$f"; }
  done
  log "پشتیبان: $BK"
fi

# ── گام ۲: تغییر نام شبکه داکر و مسیر ریشه ────────────────
# تنها ارجاع دامنه‌ای در کل زیرساخت همین است.
if [ "$ALREADY" = "0" ]; then
  log "تغییر نام شبکه داکر و مسیرها"
  # ترتیب مهم است: مسیر بلندتر اول، وگرنه 6g-network-raft به
  # health-network-raft تبدیل می‌شود.
  run "grep -rl '6g-network' '$DST' --exclude-dir=.git --exclude-dir=node_modules \
       --exclude-dir='.port-backup-*' 2>/dev/null \
       | xargs -r sed -i 's|6g-network-raft|$NEW_NET|g; s|$OLD_NET|$NEW_NET|g'"
fi

# ── گام ۳: حذف لایه دامنه 6G ──────────────────────────────
log "حذف لایه دامنه 6G"
for f in scripts/generateChaincodes_spatial.sh scripts/gen-spatial-contracts.js \
         scripts/upgrade-spatial.sh scripts/seed-network.sh \
         scripts/spatial-signatures.json scripts/update-fn-map.js \
         scripts/market-block.js reference/radio.go reference/radio-mirror.js \
         reference/analyse-contracts.js reference/analyse-deep.js \
         6g-network-contracts-detailed.md; do
  [ -f "$DST/$f" ] && run "rm -f '$DST/$f'"
done
# قراردادهای 6G در پوشه chaincode
[ -d "$DST/chaincode" ] && run "rm -rf '$DST/chaincode'"
# generateChaincodes_partN.sh ها هم مال 6G‌اند
run "rm -f '$DST'/scripts/generateChaincodes_part*.sh"

# ── گام ۴: نصب لایه دامنه سلامت ───────────────────────────
log "نصب لایه دامنه سلامت"
run "mkdir -p '$DST/reference' '$DST/scripts' '$DST/server'"
run "cp '$PKG/reference/clinical.go'      '$DST/reference/'"
run "cp '$PKG/reference/clinical_test.go' '$DST/reference/'"
run "cp '$PKG/reference/sim.go'           '$DST/reference/'"
run "cp '$PKG/scripts/channel_contract_map.sh'   '$DST/scripts/'"
run "cp '$PKG/scripts/gen-hospital-contracts.js' '$DST/scripts/'"
run "cp '$PKG/scripts/seed-hospital.sh'          '$DST/scripts/'"
run "cp '$PKG/scripts/check-go.js'               '$DST/scripts/'"
# خود اسکریپت انتقال هم کپی می‌شود، وگرنه به‌روزرسانی لایه دامنه
# از مقصد ممکن نیست و باید هر بار مسیر بسته اصلی را پیدا کنید.
run "cp '$PKG/scripts/port-from-6g.sh'           '$DST/scripts/'"
run "cp '$PKG/server/bench-catalog.js'           '$DST/server/'"
run "chmod +x '$DST'/scripts/*.sh"

# ── گام ۵: تولید قراردادها و مانیفست ──────────────────────
log "تولید قراردادها"
if [ "$DRY_RUN" != "1" ]; then
  (cd "$DST/scripts" && node gen-hospital-contracts.js) \
    || error "مولد شکست خورد"
fi

# ── گام ۶: همگام‌سازی fabric.js ───────────────────────────
# fabric.js نسخه دوم CHANNEL_CHAINCODE_MAP را دارد و
# assertCatalogInSync() هر واگرایی را پرچم می‌زند. اگر همین حالا
# همگامش نکنیم، مسیرهای دفتر در داشبورد کانال‌های 6G را می‌جویند.
if [ -f "$DST/server/fabric.js" ] && [ "$DRY_RUN" != "1" ]; then
  log "همگام‌سازی CHANNEL_CHAINCODE_MAP در fabric.js"
  node - "$DST" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const dst = process.argv[2];
const { CHANNEL_CHAINCODE_MAP } = require(path.join(dst, 'server', 'contract-fn-map.js'));
const p = path.join(dst, 'server', 'fabric.js');
let src = fs.readFileSync(p, 'utf8');
const re = /const CHANNEL_CHAINCODE_MAP\s*=\s*\{[\s\S]*?\n\};/;
if (!re.test(src)) {
  console.error('  هشدار: بلوک CHANNEL_CHAINCODE_MAP در fabric.js پیدا نشد — دستی همگام کنید');
  process.exit(0);
}
src = src.replace(re,
  'const CHANNEL_CHAINCODE_MAP = ' + JSON.stringify(CHANNEL_CHAINCODE_MAP, null, 2) + ';');
fs.writeFileSync(p, src);
console.log('  fabric.js همگام شد');
NODEEOF
fi

# ── گام ۷: تأیید ─────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN — هیچ تغییری اعمال نشد"
  exit 0
fi

log "تأیید ساختاری"
FAIL=0

check() {
  if eval "$2" >/dev/null 2>&1; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1"
    FAIL=$((FAIL+1))
  fi
}

# خودِ این اسکریپت طبعاً نام قدیمی را دارد (متغیر OLD_NET و
# مستنداتش) و باید از بررسی مستثنا شود، وگرنه پس از کپی شدن به
# مقصد، هر اجرای دوباره خودش را به‌عنوان باقیمانده گزارش می‌کند.
check "شبکه داکر تغییر نام یافت" \
      "! grep -rq --exclude=port-from-6g.sh '$OLD_NET' '$DST/config' '$DST/scripts'"
check "لایه دامنه 6G حذف شد" \
      "[ ! -f '$DST/reference/radio.go' ]"
check "clinical.go نصب شد" \
      "[ -f '$DST/reference/clinical.go' ]"
check "اسکریپت قراردادها تولید شد" \
      "[ -s '$DST/scripts/generateChaincodes_hospital.sh' ]"
check "مانیفست امضاها تولید شد" \
      "[ -s '$DST/scripts/hospital-signatures.json' ]"
check "contract-fn-map.js تولید شد" \
      "[ -s '$DST/server/contract-fn-map.js' ]"
check "کاتالوگ بنچمارک بارگذاری می‌شود" \
      "cd '$DST/server' && node -e 'require(\"./bench-catalog\").catalog()'"
check "کاتالوگ با fabric.js همگام است" \
      "cd '$DST/server' && node -e '
        const d=require(\"./bench-catalog\").assertCatalogInSync();
        if(d.length) { console.error(d); process.exit(1); }'"
check "زیرساخت TLS/Raft دست‌نخورده" \
      "[ -f '$DST/scripts/set-tls.sh' ] && [ -f '$DST/scripts/setup-raft.sh' ] \
       && [ -f '$DST/scripts/builders/golang/bin/run' ]"

if [ -x "$(command -v go)" ]; then
  check "هسته بالینی آزمون می‌دهد" \
        "cd '$DST/reference' && (printf 'module clinical\ngo 1.21\n' > /tmp/_gm && cp /tmp/_gm go.mod) && go test ./... && rm -f go.mod"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  error "$FAIL بررسی شکست خورد. پشتیبان در $BK"
fi

cat <<EOF

انتقال کامل شد: $DST

گام‌های بعدی (ترتیب مهم است):

  cd $DST
  bash scripts/generateChaincodes_hospital.sh      # تولید + کامپایل
  NODES=3 CHANNELS="admissionchannel auditchannel" \\
      ./scripts/bootstrap-secure.sh                # TLS + Raft + کانال + قرارداد
  ./scripts/seed-hospital.sh                       # بذرکاری چیدمان مراکز
  bash scripts/patch-tls-detect.sh                 # پیش از دو خط بعد
  node scripts/gen-caliper-network.js
  ./scripts/fix-tape-policy.sh

یادآوری‌هایی که همچنان برقرارند:
  · docker compose down همیشه با -v وقتی بلوک پیدایش عوض شده
  · بعد از هر git pull: bash server/patch-index.sh
  · patch-tls-detect.sh باید پیش از gen-caliper-network.js بیاید
EOF
