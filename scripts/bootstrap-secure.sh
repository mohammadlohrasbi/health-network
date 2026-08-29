#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# bootstrap-secure.sh — راه‌اندازی شبکه از صفر با TLS کامل و Raft.
#
# چرا این اسکریپت وجود دارد
# ─────────────────────────
# سه قطعه باید به ترتیب درست اجرا شوند، وگرنه بی‌صدا شکست می‌خورند:
#
#   network.sh    مواد رمزنگاری و MSP می‌سازد
#   setup-raft.sh نودهای اضافی و configtx را می‌سازد
#   set-tls.sh گواهی TLS همه نودها را صادر می‌کند
#
# ترتیب اهمیت دارد چون setup-raft پوشه نودهای جدید را می‌سازد و set-tls
# باید بعد از آن بیاید تا گواهی همه‌شان را از یک CA صادر کند. اگر برعکس
# شود، نودهای جدید گواهی ندارند و Raft — که با pinning کار می‌کند —
# آنها را نمی‌پذیرد.
#
# و بلوک پیدایش باید پس از هر دو ساخته شود، چون هم نوع سرویس ترتیب‌دهی و
# هم مسیر گواهی consenter ها را در خود دارد.
#
# استفاده:
#   ./bootstrap-secure.sh              # ۳ نود Raft، TLS کامل، admissionchannel + auditchannel
#   NODES=5 ./bootstrap-secure.sh
#   CHANNELS="admissionchannel auditchannel" ./bootstrap-secure.sh
#   CHANNELS=all ./bootstrap-secure.sh          # هر 20 کانال (طولانی)
#   SKIP_NETWORK=1 ./bootstrap-secure.sh        # اگر crypto از قبل هست
#   DRY_RUN=1 ./bootstrap-secure.sh
#
# ⚠ این اسکریپت شبکه موجود را پاک می‌کند. دفتر فعلی از بین می‌رود.
# ══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT_DIR="${ROOT_DIR:-/root/health-network}"
SCRIPTS="$ROOT_DIR/scripts"
CONFIG="$ROOT_DIR/config"
NODES="${NODES:-3}"
CHANNELS="${CHANNELS:-admissionchannel auditchannel}"
# کانال شاهد بنچمارک. با WITH_CONTROL=0 خاموش می‌شود.
CONTROL_CHANNEL="${CONTROL_CHANNEL:-auditchannel}"
WITH_CONTROL="${WITH_CONTROL:-1}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_NETWORK="${SKIP_NETWORK:-0}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}!${NC} $*"; }
die()   { echo -e "  ${RED}✗${NC} $*"; exit 1; }
run()   { if [ "$DRY_RUN" = "1" ]; then echo "    \$ $*"; else "$@"; fi; }

echo ""
echo "════════════════════════════════════════════"
echo " راه‌اندازی شبکه ملی سلامت از صفر"
echo "   Raft با $NODES نود | TLS کامل"
echo "   کانال‌ها: $CHANNELS"
echo "════════════════════════════════════════════"
[ "$DRY_RUN" = "1" ] && warn "DRY_RUN — فقط دستورها نشان داده می‌شوند"

# ── پیش‌نیازها ──
step "بررسی پیش‌نیازها"
for s in network.sh setup-raft.sh set-tls.sh deploy-staged.sh seed-hospital.sh; do
    [ -f "$SCRIPTS/$s" ] || die "$s نیست"
done
ok "اسکریپت‌ها"

# ── اعتبارسنجی کانال‌های خواسته‌شده ──
# پیش از هر کار مخرب. نام کانال از channel_contract_map.sh خوانده
# می‌شود که همان منبعی است که deploy-staged.sh هم می‌خواند.
if [ "$CHANNELS" != "all" ]; then
    WANTED="$CHANNELS"
    # shellcheck source=/dev/null
    source "$SCRIPTS/channel_contract_map.sh"
    RESOLVED=""
    BAD=""
    for want in $WANTED; do
        got="$(resolve_channel "$want")" || { BAD="$BAD $want"; continue; }
        # تکراری نشود: datachannel و sessionchannel هر دو به
        # admissionchannel ترجمه می‌شوند.
        case " $RESOLVED " in *" $got "*) ;; *) RESOLVED="$RESOLVED $got";; esac
    done
    if [ -n "$BAD" ]; then
        echo
        warn "کانال ناشناخته:$BAD"
        warn "هیچ کاری انجام نشد — شبکه فعلی دست‌نخورده است."
        echo
        echo "  کانال‌های موجود:"
        printf '    %s\n' "${CHANNELS[@]}"
        echo
        echo "  پیشنهاد برای اولین اجرا:"
        echo "    CHANNELS=\"admissionchannel auditchannel\" ./bootstrap-secure.sh"
        exit 1
    fi
    CHANNELS="${RESOLVED# }"

    # کانال شاهد: بدون آن، عدد بنچمارک کانال selector با هیچ چیز
    # قابل مقایسه نیست. ۷ قرارداد نوشتن کور، هزینه‌اش ناچیز.
    if [ "$WITH_CONTROL" = "1" ]; then
        case " $CHANNELS " in
            *" $CONTROL_CHANNEL "*) ;;
            *)
                CHANNELS="$CHANNELS $CONTROL_CHANNEL"
                warn "کانال شاهد «$CONTROL_CHANNEL» خودکار اضافه شد (آزمایش مقایسه‌ای)"
                warn "برای خاموش کردن: WITH_CONTROL=0"
                ;;
        esac
    fi
    ok "کانال‌ها معتبرند: $CHANNELS"
fi
for t in docker go node openssl; do
    command -v "$t" >/dev/null 2>&1 || die "$t نصب نیست"
done
ok "ابزارها"
docker compose version >/dev/null 2>&1 || die "docker compose v2 لازم است"
ok "docker compose v2"

FREE_MB=$(free -m | awk '/^Mem:/{print $7}')
NEEDED=$((1200 + NODES * 200))
if [ "$FREE_MB" -lt "$NEEDED" ]; then
    warn "حافظه آزاد ${FREE_MB}MB — برای $NODES نود حدود ${NEEDED}MB توصیه می‌شود"
    if [ "$NODES" -gt 3 ]; then
        warn "با NODES=3 دوباره امتحان کنید (هر نود اضافه ~200MB)"
    else
        warn "کمترین پیکربندی همین است. پیش از ادامه:"
        warn "  systemctl stop dashboard 2>/dev/null"
        warn "  docker system prune -f"
        warn "مصرف اوج هنگام کامپایل Go قراردادهاست، نه اجرای peer ها —"
        warn "پس اگر گام ۴/۷ گذشت، بقیه معمولاً می‌گذرد."
    fi
else
    ok "حافظه: ${FREE_MB}MB آزاد"
fi

# ── هشدار پاک شدن ──
if [ "$DRY_RUN" != "1" ] && [ "$SKIP_NETWORK" != "1" ]; then
    echo ""
    warn "این کار شبکه فعلی و کل دفتر را پاک می‌کند."
    warn "نتایج بنچمارک در test-tools/bench-runs دست‌نخورده می‌مانند."
    # روی ترمینال غیرتعاملی (لوله، CI، بررسی خودکار) اصلاً
    # نپرس — بلوکه شدن بدتر از لغو است، چون هیچ نشانه‌ای نمی‌دهد.
    # برای اجرای بدون نظارت: CONFIRM=yes
    if [ "${CONFIRM:-}" = "yes" ]; then
        reply=yes
    elif [ ! -t 0 ]; then
        echo "  ورودی تعاملی نیست — لغو شد. برای ادامه: CONFIRM=yes"
        exit 0
    else
        read -r -p "  ادامه؟ (بنویسید yes) " reply
    fi
    [ "${reply:-}" = "yes" ] || { echo "لغو شد."; exit 0; }
fi

cd "$SCRIPTS" || die "به $SCRIPTS نمی‌رود"

# ── ۰) هم‌راستاسازی مسیرها ──
# چند اسکریپت مخزن مسیر پروژه را ثابت در خود دارند. اگر پروژه جای دیگری
# باشد، آنها به فایلی اشاره می‌کنند که وجود ندارد — یا بدتر، به نسخه
# قدیمی پروژه در مسیر اصلی.
if [ -f "$SCRIPTS/fix-paths.sh" ]; then
    step "۰/۷  هم‌راستاسازی مسیرها"
    if [ "$DRY_RUN" = "1" ]; then
        DRY_RUN=1 bash "$SCRIPTS/fix-paths.sh" "$ROOT_DIR" 2>&1 | tail -4
    else
        bash "$SCRIPTS/fix-paths.sh" "$ROOT_DIR" 2>&1 | grep -E "✓|✗|اصلاح‌شده" || true
    fi
fi

# ── CA ──
# گواهی TLS نودها از CA میانی صادر می‌شود. اگر بالا نباشد، network.sh به
# fallback خودامضا می‌افتد — که برای Raft کشنده است، چون نودها با pinning
# همدیگر را می‌شناسند و ریشه‌های جدا یکدیگر را تأیید نمی‌کنند.
if [ "$DRY_RUN" != "1" ] && [ "$NODES" -gt 1 ]; then
    if ! docker ps --format '{{.Names}}' | grep -q '^rca-main$'; then
        step "پیش‌نیاز: راه‌اندازی CA"
        (cd "$CONFIG" && docker compose -f docker-compose-root-ca.yml up -d) >/dev/null 2>&1
        sleep 8
        if docker ps --format '{{.Names}}' | grep -q '^rca-main$'; then
            ok "CA بالا آمد"
        else
            warn "rca-main بالا نیامد — network.sh خودش تلاش می‌کند"
        fi
    fi
fi

# ── ۱) شبکه پایه ──
step "۱/۷  مواد رمزنگاری و شبکه پایه"
if [ "$SKIP_NETWORK" = "1" ]; then
    warn "رد شد (SKIP_NETWORK=1)"
else
    # NETWORK_TLS=true باعث می‌شود tlscacerts در MSP قرار بگیرد — بدون آن
    # Gateway ریشه اعتماد ندارد و set-tls بعداً باید خودش اضافه کند.
    # ORDERER_NODES هم لازم است: بدون آن network.sh فقط برای یک orderer
    # هویت و گواهی می‌سازد و خوشه Raft بعداً دو نود بی‌گواهی خواهد داشت.
    run env NETWORK_TLS=true ORDERER_NODES="$NODES" ./network.sh || die "network.sh شکست خورد"
    ok "شبکه پایه ساخته شد"
fi

# ── ۲) Raft ──
step "۲/۷  پیکربندی Raft"
run ./setup-raft.sh "$NODES" || die "setup-raft.sh شکست خورد"
ok "configtx و docker-compose برای $NODES نود"

# ── ۳) TLS ──
# بعد از Raft، تا پوشه نودهای جدید وجود داشته باشد و گواهی همه‌شان از
# یک CA صادر شود.
step "۳/۷  گواهی‌های TLS"
run ./set-tls.sh on || die "set-tls.sh شکست خورد"
ok "TLS روی همه نودها"

# ── ۴) قراردادها ──
step "۴/۷  تولید قراردادها"
if [ "$DRY_RUN" = "1" ]; then
    echo "    \$ node gen-hospital-contracts.js && bash generateChaincodes_hospital.sh"
else
    # اسکریپت تولید، خودش تولیدشده است. اول از مولد بازش می‌سازیم تا
    # نسخه commit شده هرگز از مولد عقب نماند — دقیقاً همان چیزی که
    # باعث شد قراردادها یک بار دیگر در مسیر قدیمی ساخته شوند.
    node gen-hospital-contracts.js >/dev/null \
        || die "gen-hospital-contracts.js شکست خورد"
    bash generateChaincodes_hospital.sh \
        || die "generateChaincodes_hospital.sh شکست خورد — جداگانه اجرا کنید تا خطای کامپایل دیده شود"
    COUNT=$(find "$SCRIPTS/chaincode" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    [ "$COUNT" -eq 110 ] || die "$COUNT قرارداد تولید شد، انتظار 110"
    ok "110 قرارداد — اسکریپت خودش کامپایل را بررسی کرد"
fi

# ── ۵) بلوک پیدایش ──
# باید پس از Raft و TLS بیاید: هم نوع سرویس ترتیب‌دهی و هم مسیر گواهی
# consenter ها داخل بلوک پیدایش می‌روند.
step "۵/۷  بلوک پیدایش"
run ./deploy-staged.sh artifacts || die "ساخت آرتیفکت شکست خورد"

# بلوک پیدایش را deploy-staged نمی‌سازد — فقط فایل‌های .tx کانال‌ها را.
# بلوک را network.sh می‌سازد، ولی آن پیش از setup-raft اجرا شده و در آن
# لحظه configtx هنوز solo بوده. پس اینجا از نو ساخته می‌شود تا etcdraft و
# گواهی consenter ها واقعاً داخلش بنشینند.
#
# نشانه‌اش وقتی این گام جا بیفتد: orderer با «consensus type: solo» بالا
# می‌آید هرچند configtx.yaml می‌گوید etcdraft.
if [ "$DRY_RUN" = "1" ]; then
    echo "    \$ configtxgen -profile OrdererGenesis -channelID system-channel \\"
    echo "        -outputBlock channel-artifacts/genesis.block"
else
    rm -f "$CONFIG/channel-artifacts/genesis.block"
    (cd "$CONFIG" && FABRIC_CFG_PATH="$CONFIG" configtxgen \
        -profile OrdererGenesis -channelID system-channel \
        -outputBlock channel-artifacts/genesis.block) >/dev/null 2>&1 \
        || die "ساخت بلوک پیدایش شکست خورد"

    # تأیید که نوع اجماع واقعاً در بلوک نشسته
    if [ "$NODES" -gt 1 ]; then
        if (cd "$CONFIG" && configtxgen -inspectBlock channel-artifacts/genesis.block 2>/dev/null) \
             | grep -qi etcdraft; then
            ok "بلوک پیدایش با etcdraft"
        else
            die "بلوک پیدایش ساخته شد ولی etcdraft در آن نیست — configtx.yaml را بررسی کنید"
        fi
    else
        ok "بلوک پیدایش"
    fi
fi

# ── ۶) بالا آوردن ──
step "۶/۷  راه‌اندازی کانتینرها"
if [ "$DRY_RUN" = "1" ]; then
    echo "    \$ cd $CONFIG && docker compose down && docker compose up -d"
else
    # اوردررهای Raft در docker-compose با profile تعریف شده‌اند: بدون آن
    # فقط یکی بالا می‌آید و خوشه‌ای که بلوک پیدایش سه نود اعلام کرده
    # هرگز رهبر انتخاب نمی‌کند.
    PROFILE_ARG=""
    if [ "$NODES" -gt 3 ]; then
        PROFILE_ARG="--profile raft5"
    elif [ "$NODES" -gt 1 ]; then
        PROFILE_ARG="--profile raft"
    fi
    # volume ها باید بروند.
    #
    # orderer وقتی در volume خودش یک system channel پیدا کند می‌گوید
    # «bootstrap نمی‌کنم» و بلوک پیدایش تازه را نادیده می‌گیرد — یعنی با
    # نوع اجماع قبلی بالا می‌آید. این تنها جایی است که پاک کردن volume
    # لازم است، و چون این اسکریپت از صفر می‌سازد، ضرری ندارد.
    (cd "$CONFIG" && docker compose $PROFILE_ARG down --remove-orphans >/dev/null 2>&1) || true
    docker volume ls -q 2>/dev/null | grep -E "orderer|peer0" | xargs -r docker volume rm >/dev/null 2>&1 || true
    (cd "$CONFIG" && docker compose $PROFILE_ARG up -d) || die "بالا آوردن کانتینرها شکست خورد"

    echo -n "  انتظار برای انتخاب رهبر Raft"
    LEADER=""
    for i in $(seq 1 30); do
        sleep 2; echo -n "."
        LEADER=$(docker logs orderer.example.com 2>&1 \
            | grep -oiE "became leader at term|leader changed|Raft leader" | tail -1)
        [ -n "$LEADER" ] && break
    done
    echo ""
    if [ -n "$LEADER" ]; then
        ok "خوشه Raft فعال است"
    else
        warn "رهبری در لاگ دیده نشد — با این بررسی کنید:"
        echo "     docker logs orderer.example.com 2>&1 | tail -20"
    fi
fi

# ── ۷) کانال‌ها و قراردادها ──
step "۷/۷  استقرار کانال‌ها"
if [ "$CHANNELS" = "all" ]; then
    run ./deploy-staged.sh all || warn "استقرار کامل با خطا — با list بررسی کنید"
else
    for ch in $CHANNELS; do
        echo "  ── $ch ──"
        run ./deploy-staged.sh channel "$ch" || warn "$ch با خطا"
    done
fi

if [ "$DRY_RUN" != "1" ]; then
    echo ""
    ./deploy-staged.sh list
    echo ""
    # بذرکاری فقط وقتی معنا دارد که قراردادی مستقر شده باشد
    COMMITTED=$(./deploy-staged.sh list 2>/dev/null | grep -oE "[1-9][0-9]*/[0-9]+" | head -1)
    if [ -n "$COMMITTED" ]; then
        ok "قراردادها مستقر شدند — بذرکاری چیدمان مراکز"
        for ch in $CHANNELS; do
            [ "$ch" = "all" ] && ./seed-hospital.sh || ./seed-hospital.sh "$ch"
        done
    else
        die "هیچ قراردادی commit نشد — خروجی بالا را بررسی کنید"
    fi
fi

# ── ابزارها و سرویس ──
step "ابزارهای تست و داشبورد"
if [ "$DRY_RUN" != "1" ]; then
    # پیش از تولید پروفایل‌ها: config.js باید وضعیت TLS را از .env بخواند.
    # این اسکریپت‌ها اینجا بدون متغیر محیطی سرویس اجرا می‌شوند، پس بدون این
    # وصله پیکربندی بدون TLS می‌سازند — و هر تراکنش بنچمارک رد می‌شود
    # بی‌آنکه خطای گواهی دیده شود.
    [ -f ./patch-tls-detect.sh ] && ./patch-tls-detect.sh >/dev/null 2>&1 \
        && ok "تشخیص TLS از .env"
    node gen-caliper-network.js >/dev/null 2>&1 && ok "پروفایل‌های Caliper (grpcs://)"
    ./fix-tape-policy.sh >/dev/null 2>&1 && ok "سیاست Tape"
    node gen-hospital-contracts.js >/dev/null 2>&1 && ok "نگاشت توابع و مانیفست امضاها"
    bash "$ROOT_DIR/server/patch-index.sh" >/dev/null 2>&1 && ok "سرور پچ شد"
    systemctl restart dashboard 2>/dev/null && ok "داشبورد ری‌استارت شد"
fi

echo ""
echo "════════════════════════════════════════════"
[ "$DRY_RUN" = "1" ] && { echo "DRY_RUN تمام شد."; exit 0; }
echo -e "${GREEN} شبکه با Raft ($NODES نود) و TLS کامل بالا آمد.${NC}"
echo "════════════════════════════════════════════"
cat <<'NEXT'

بررسی‌های پیشنهادی:

  # رهبر خوشه
  docker logs orderer.example.com 2>&1 | grep -i leader | tail -3

  # تحمل خطا — نود رهبر را بخوابانید و ببینید شبکه کار می‌کند
  docker stop orderer.example.com
  ./deploy-staged.sh list          # باید همچنان جواب بدهد
  docker start orderer.example.com

NEXT

echo "آمادگی بنچمارک:"
for _ch in $CHANNELS; do
    _st=$(./deploy-staged.sh list 2>/dev/null | grep -E "^[[:space:]]*${_ch}[[:space:]]" \
          | grep -oE '[0-9]+/[0-9]+' | head -1)
    printf '  %-20s %s\n' "$_ch" "${_st:-نامشخص}"
done

cat <<'NEXT'

آزمایش شاهد — همان شبکه، همان سیاست، تنها تفاوت کار chaincode:
  admissionchannel  ۷ قرارداد selector — تریاژ NEWS2، انتخاب مرکز از
                    میان ۱۲، کنترل پذیرش. ممکن است رد کند.
  auditchannel      ۷ قرارداد ledger — نوشتن کور، هرگز رد نمی‌کند.

  اختلاف گذردهی این دو = «هزینه پیچیدگی chaincode».
  پیش‌بینی بر پایه یافته پروژه 6G: قابل اندازه‌گیری نخواهد بود،
  چون گلوگاه اجماع است نه اجرای chaincode.

  ⚠️ نرخ رد selector (شبیه‌سازی: ~۸٪، همه «خارج از پنجره طلایی»)
     متریک دامنه است نه خطا — در گزارش جدا از نرخ خطا بیاید.

آزمایش‌های دیگری که این معماری ممکن کرد:
  # بهای تحمل خطا — همان بنچمارک با solo و با Raft
  ./setup-raft.sh solo   # سپس بازسازی از گام ۵

  # منحنی گذردهی بر حسب تعداد امضا
  CC_POLICY="OutOf(3,...)" ./upgrade-chaincode.sh admissionchannel

  # کنترل پذیرش و کلید داغ (۱۲ مرکز، نرخ بالا → تعارض MVCC)
  TRACK_BEDS=1 ./seed-hospital.sh admissionchannel

ارتقای قرارداد بدون بازسازی شبکه — دیگر لازم نیست از نو بسازید:
  ./upgrade-chaincode.sh admissionchannel
NEXT
