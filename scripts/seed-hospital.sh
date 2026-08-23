#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# seed-hospital.sh — بذرکاری چیدمان مراکز روی هر قرارداد مستقر
#
# قرینه seed-network.sh پروژه 6G و به همان دلیل وجود دارد:
# هر chaincode فضای حالت **مستقل** دارد، پس رجیستری مشترک ممکن
# نیست و هر قرارداد باید چیدمان خودش را از همان بذر بسازد. با بذر
# یکسان، همه قراردادها همان نقشه را می‌بینند.
#
# ⚠️ آرگومان‌ها باید با BENCH_SEED / GRID_SIZE_M / FACILITY_COUNT در
# server/bench-catalog.js **دقیقاً** یکی باشند. اگر نباشند، بنچمارک
# بیمارانی می‌سازد که خارج از شبکه بذرکاری‌شده‌اند و همه رد می‌شوند —
# و شما رد را به پای شبکه می‌نویسید. در 6G همین اتفاق افتاد وقتی
# مختصات ۱..۱۰۰ روی شبکه ۱۰ کیلومتری ارزیابی شد.
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DIR="${ROOT_DIR:-/root/health-network}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SEED="${SEED:-seed-1404}"
GRID_M="${GRID_M:-30000}"
FACILITIES="${FACILITIES:-12}"
# ۰ = ردیابی ظرفیت خاموش. به هشدار «کلید داغ» در README مراجعه کنید:
# با روشن بودن، هر تراکنش رکورد مرکز را بازمی‌نویسد و با ۱۲ مرکز
# دوازده کلید داغ می‌سازد.
TRACK_BEDS="${TRACK_BEDS:-0}"

DRY_RUN="${DRY_RUN:-0}"

source "$SCRIPT_DIR/channel_contract_map.sh"

# ── محدود کردن به کانال‌های خواسته‌شده ──────────────────
# bootstrap-secure.sh این اسکریپت را با یک نام کانال صدا می‌زند
# (`./seed-hospital.sh admissionchannel`). نسخه اول آرگومان را
# نادیده می‌گرفت و هر ۲۰ کانال را بذرکاری می‌کرد — یعنی صدها
# فراخوانی روی کانال‌هایی که هنوز ساخته نشده‌اند، همه ناموفق، و
# اسکریپت با exit 1 راه‌اندازی را می‌خواباند در حالی که کانال
# واقعی درست بذرکاری شده بود.
if [ "$#" -gt 0 ] && [ "$1" != "all" ]; then
  RESOLVED=()
  for want in "$@"; do
    if got="$(resolve_channel "$want")"; then
      case " ${RESOLVED[*]:-} " in *" $got "*) ;; *) RESOLVED+=("$got");; esac
    else
      echo "خطا: کانال ناشناخته '$want'. کانال‌های موجود:" >&2
      printf '  %s\n' "${CHANNELS[@]}" >&2
      exit 1
    fi
  done
  CHANNELS=("${RESOLVED[@]}")
fi
source "$SCRIPT_DIR/deploy_functions.sh" 2>/dev/null || true

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
warn() { echo "[$(date +'%H:%M:%S')] هشدار: $*" >&2; }

# ── بررسی همخوانی با کاتالوگ بنچمارک ──────────────────────
CATALOG="$ROOT_DIR/server/bench-catalog.js"
if [ -f "$CATALOG" ] && command -v node >/dev/null; then
  read -r C_SEED C_GRID C_FAC <<< "$(cd "$ROOT_DIR/server" && node -e '
    const c = require("./bench-catalog");
    console.log(c.BENCH_SEED, c.GRID_SIZE_M, c.FACILITY_COUNT);
  ' 2>/dev/null)"
  if [ -n "${C_SEED:-}" ]; then
    if [ "$C_SEED" != "$SEED" ] || [ "$C_GRID" != "$GRID_M" ] || [ "$C_FAC" != "$FACILITIES" ]; then
      warn "ناهمخوانی با bench-catalog.js:"
      warn "  بذرکاری : بذر=$SEED شبکه=$GRID_M مراکز=$FACILITIES"
      warn "  کاتالوگ : بذر=$C_SEED شبکه=$C_GRID مراکز=$C_FAC"
      warn "بنچمارک بیمارانی خارج از شبکه می‌سازد و همه رد می‌شوند."
      warn "یکی از دو طرف را اصلاح کنید. برای ادامه با اجبار: FORCE=1"
      [ "${FORCE:-0}" = "1" ] || exit 1
    else
      log "همخوانی با bench-catalog.js تأیید شد"
    fi
  fi
fi

log "بذر=$SEED شبکه=${GRID_M}m مراکز=$FACILITIES ردیابی_تخت=$TRACK_BEDS"
log "کانال‌ها: ${CHANNELS[*]}"

OK=0; FAILED=0; SKIPPED=0
FAILED_LIST=""

for ch in "${CHANNELS[@]}"; do
  for cc in ${CHANNEL_CONTRACTS[$ch]}; do

    # فقط قراردادهایی که واقعاً بذر لازم دارند. BalanceOf فقط
    # خواندن است و تابع نوشتنی ندارد.
    if [ "$cc" = "BalanceOf" ]; then
      SKIPPED=$((SKIPPED+1)); continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      echo "  [dry] $ch/$cc SeedFacilityLayout $SEED $GRID_M $FACILITIES $TRACK_BEDS"
      OK=$((OK+1)); continue
    fi

    # invoke_chaincode از deploy_functions.sh می‌آید و فلگ‌های TLS را
    # خودش می‌گذارد (set-tls.sh آن را پچ کرده).
    if invoke_chaincode "$ch" "$cc" \
        "{\"function\":\"SeedFacilityLayout\",\"Args\":[\"$SEED\",\"$GRID_M\",\"$FACILITIES\",\"$TRACK_BEDS\"]}" \
        >/dev/null 2>&1; then
      OK=$((OK+1))
      printf '.'
    else
      FAILED=$((FAILED+1))
      FAILED_LIST="$FAILED_LIST $ch/$cc"
      printf 'x'
    fi
  done
done

echo
log "بذرکاری تمام شد: موفق=$OK ناموفق=$FAILED رد‌شده=$SKIPPED"

if [ "$FAILED" -gt 0 ]; then
  warn "قراردادهای ناموفق:$FAILED_LIST"
  warn "علت‌های محتمل: قرارداد commit نشده، کانال ساخته نشده،"
  warn "یا فلگ TLS غایب. با 'docker logs peer0.org1.example.com' بررسی کنید."
  exit 1
fi

# ── تأیید ────────────────────────────────────────────────
# در 6G یاد گرفتیم که «موفق» گزارش‌شده کافی نیست — deploy-staged.sh
# پنج بار پیاپی موفقیت اعلام کرد در حالی که ۰/۴ قرارداد commit شده
# بود. پس واقعاً از زنجیره می‌پرسیم.
if [ "$DRY_RUN" != "1" ]; then
  log "تأیید: پرس‌وجوی NetworkStatus از یک قرارداد نمونه"
  FIRST_CH="${CHANNELS[0]}"
  FIRST_CC="$(echo ${CHANNEL_CONTRACTS[$FIRST_CH]} | awk '{print $1}')"
  query_chaincode "$FIRST_CH" "$FIRST_CC" \
    '{"function":"NetworkStatus","Args":[]}' 2>&1 | tail -2
fi
