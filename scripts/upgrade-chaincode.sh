#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# upgrade-chaincode.sh — ارتقای درجای قرارداد، بدون بازسازی شبکه
#
# قرینه upgrade-spatial.sh پروژه 6G و به همان دلیل وجود دارد:
# تا وقتی `--sequence` ثابت ۱ بود، هر تغییر کوچک در کد قرارداد
# یعنی پاک کردن CA، گواهی‌ها، خوشه Raft، کانال‌ها و بذرکاری —
# بیست دقیقه برای عوض کردن یک خط.
#
# حالا deploy_functions.sh توالی را از خود زنجیره می‌خواند، پس
# این اسکریپت فقط سه کار می‌کند: بازتولید کد، بسته‌بندی دوباره،
# و approve/commit با توالی بعدی.
#
# استفاده:
#   ./upgrade-chaincode.sh admissionchannel              # کل کانال
#   ./upgrade-chaincode.sh admissionchannel TriagePatient # یک قرارداد
#   RESEED=1 ./upgrade-chaincode.sh admissionchannel     # + بذرکاری دوباره
#
# ⚠️ ارتقا حالت دفتر را **پاک نمی‌کند**. اگر ساختار داده عوض شده
# (فیلد جدید در Record یا NetConfig)، رکوردهای قدیمی با کد جدید
# خوانده می‌شوند و ممکن است مقدار صفر بدهند. در آن حالت RESEED=1
# لازم است، و برای تغییر ناسازگار، بازسازی کامل.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail
trap 'rc=$?; echo "[خطا] خط $LINENO، کد $rc: $BASH_COMMAND" >&2; exit $rc' ERR

ROOT_DIR="${ROOT_DIR:-/root/health-network}"
SCRIPTS="$ROOT_DIR/scripts"
RESEED="${RESEED:-0}"
SKIP_GEN="${SKIP_GEN:-0}"

cd "$SCRIPTS"

# shellcheck source=/dev/null
source "$SCRIPTS/channel_contract_map.sh"
# shellcheck source=/dev/null
source "$SCRIPTS/deploy_functions.sh"

log()   { echo "[$(date +'%H:%M:%S')] $*"; }
die()   { echo "[$(date +'%H:%M:%S')] خطا: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "استفاده: ./upgrade-chaincode.sh <کانال> [قرارداد]"

RAW_CH="$1"
ONE_CC="${2:-}"

CH="$(resolve_channel "$RAW_CH")" || {
  echo "کانال‌های موجود:" >&2
  printf '  %s\n' "${CHANNELS[@]}" >&2
  die "کانال ناشناخته: $RAW_CH"
}

CONTRACTS="${CHANNEL_CONTRACTS[$CH]}"
if [ -n "$ONE_CC" ]; then
  case " $CONTRACTS " in
    *" $ONE_CC "*) CONTRACTS="$ONE_CC" ;;
    *) die "قرارداد $ONE_CC روی کانال $CH نیست" ;;
  esac
fi

# ── بررسی اینکه کانال واقعاً وجود دارد ────────────────────
# بدون این، اسکریپت کل کد را بازتولید می‌کند و بعد روی
# approve می‌افتد. ارزان است، پس اول بررسی می‌شود.
if ! docker exec peer0.org1.example.com peer channel list 2>/dev/null | grep -q "^$CH\$"; then
  die "کانال $CH روی peer0.org1 نیست — اول ./deploy-staged.sh channel $CH"
fi

log "ارتقای کانال $CH — $(echo "$CONTRACTS" | wc -w) قرارداد"

# ── ۱) بازتولید کد ────────────────────────────────────────
# مولد هم اسکریپت تولید را می‌سازد و هم مانیفست امضاها، پس
# نسخه commit شده هرگز از مولد عقب نمی‌ماند.
if [ "$SKIP_GEN" != "1" ]; then
  log "بازتولید قراردادها"
  node gen-hospital-contracts.js >/dev/null || die "مولد شکست خورد"
  bash generateChaincodes_hospital.sh >/dev/null \
    || die "تولید/کامپایل شکست خورد — جداگانه اجرا کنید تا خطا دیده شود"
  log "  کد تازه و کامپایل‌شده"
fi

# ── ۲) نصب و ارتقا ────────────────────────────────────────
OK=0; FAILED=0; FAILED_LIST=""

for cc in $CONTRACTS; do
  # dev-container قدیمی باید برود، وگرنه peer نسخه قبلی را
  # اجرا می‌کند و شما فکر می‌کنید ارتقا اثر نداشته.
  cleanup_dev_containers "$cc" || true

  if install_one_chaincode "$cc" "$CH" >/dev/null 2>&1; then
    pkgid=$(docker exec peer0.org1.example.com \
      peer lifecycle chaincode queryinstalled 2>/dev/null \
      | sed -n "s/^Package ID: \\(${cc}_[^,]*\\), Label.*/\\1/p" | tail -1)
  else
    pkgid=""
  fi

  if [ -z "$pkgid" ]; then
    FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST $cc"
    echo "  ✗ $cc — نصب ناموفق"
    continue
  fi

  if approve_commit_one "$cc" "$CH" "$pkgid"; then
    OK=$((OK+1))
  else
    FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST $cc"
  fi
done

echo
log "ارتقا تمام شد: موفق=$OK ناموفق=$FAILED"
[ "$FAILED" -eq 0 ] || die "قراردادهای ناموفق:$FAILED_LIST"

# ── ۳) بذرکاری دوباره (اختیاری) ───────────────────────────
# ارتقا حالت را پاک نمی‌کند، پس چیدمان مراکز سر جایش است. ولی
# اگر ساختار NetConfig یا Facility عوض شده باشد، رکوردهای قدیمی
# با کد جدید ناقص خوانده می‌شوند.
if [ "$RESEED" = "1" ]; then
  log "بذرکاری دوباره"
  ./seed-hospital.sh "$CH"
fi

# ── ۴) تأیید ──────────────────────────────────────────────
FIRST_CC="$(echo "$CONTRACTS" | awk '{print $1}')"
log "تأیید: NetworkStatus روی $FIRST_CC"
query_chaincode "$CH" "$FIRST_CC" '{"function":"NetworkStatus","Args":[]}' \
  || die "پرس‌وجو ناموفق — اگر «هیچ مرکزی بذرکاری نشده» دیدید، RESEED=1 بزنید"
