# دستورالعمل اجرا — صفر تا صد

> **توجه:** این RUNBOOK از پروژه 6g-network-raft به ارث رسیده و
> برای شبکه سلامت ترجمه شده است. بخش‌های زیرساخت (CA، TLS، Raft،
> عیب‌یابی) بدون تغییر معتبرند چون آن لایه دامنه‌مستقل است. بخش‌های
> مربوط به قراردادها با معادل سلامت جایگزین شده‌اند. برای معماری و
> تصمیمات طراحی به `README.md` مراجعه کنید.


شبکهٔ هایپرلجر فابریک برای شبکهٔ ملی سلامت: هشت MSP در نقش دامنه اعتماد
(وزارت بهداشت، بیمه، غذا و دارو، آمار سلامت، اورژانس، بیمارستان دولتی،
بیمارستان خصوصی، آزمایشگاه و داروخانه)، بیست کانال، صد و ده قرارداد Go
با هسته قطعی بالینی (NEWS2، تریاژ، انتخاب مرکز، سازگاری خون، ایمنی دارو)،
بازار منابع، داشبورد وب، و بنچمارک با Tape و Caliper.

---

## پیش از شروع: کدام مسیر

| وضعیت شما | بروید به |
|---|---|
| از صفر می‌سازید، TLS و Raft می‌خواهید | [مسیر A](#مسیر-a--نصب-کامل-از-صفر) |
| شبکه بالاست، فقط فایل‌ها را به‌روز می‌کنید | [مسیر B](#مسیر-b--بهروزرسانی-شبکه-موجود) |
| شبکه بالاست و می‌خواهید TLS یا Raft اضافه کنید | [مسیر C](#مسیر-c--افزودن-tls-یا-raft) |

هر سه به [فاز تست](#فاز-تست) می‌رسند.

---

## پیش‌نیازها

سرور لینوکس، دست‌کم چهار گیگابایت رم به‌علاوهٔ swap، و چهل گیگابایت دیسک.

```bash
apt-get update && apt-get install -y \
    docker.io docker-compose-v2 golang nodejs npm git jq apache2-utils openssl

git clone https://github.com/mohammadlohrasbi/health-network.git /root/health-network
```

### مسیر نصب

همهٔ اسکریپت‌ها `/root/health-network` را پیش‌فرض می‌گیرند. اگر جای دیگری
کار می‌کنید، با متغیر محیطی بازنویسی کنید:

```bash
ROOT_DIR=/root/health-network ./bootstrap-secure.sh
```

**اگر شبکه‌ای از قبل در مسیر دیگری دارید**، مخزن را کپی کنید نه فقط بستهٔ
تحویلی — بستهٔ من فایل‌های پایه مثل `deploy-staged.sh` را ندارد:

```bash
cp -r /root/health-network /root/health-network
rm -rf /root/health-network/test-tools/bench-runs
cd /path/to/health-network-complete && ./install.sh /root/health-network
```

⚠ **دو شبکه هم‌زمان بالا نمی‌آیند** — پورت‌ها و نام کانتینرها یکی است.
پیش از راه‌اندازی این یکی، دیگری را پایین بیاورید:

```bash
cd /root/health-network/config && docker compose down
```

برای برگشتن به شبکهٔ قبلی، عکسش را انجام دهید. دفتر و داده‌های هر کدام در
پوشهٔ خودش دست‌نخورده می‌ماند.

**همیشه `docker compose` بدون خط تیره.** نسخهٔ v1 با داکر جدید در بازسازی
کانتینر باگ `KeyError: ContainerConfig` می‌دهد.

### حافظه

| حالت | کانتینر | حافظه |
|---|---|---|
| solo | ۱۱ | حدود ۱.۵ گیگابایت |
| Raft سه نودی | ۱۳ | حدود ۱.۸ گیگابایت |
| Raft پنج نودی | ۱۵ | حدود ۲.۲ گیگابایت |

روی سرور ۳.۷ گیگابایتی **سه نود انتخاب درست است**. پنج نود جا می‌شود ولی
هنگام استقرار که dev-container بالا می‌آید تنگ می‌شود.

---

## استقرار فایل‌های تحویلی

### اگر مخزن اختصاصی دارید

اگر `health-network` مخزن جداگانه‌ای است که همه‌چیز در آن هست:

```bash
git clone https://github.com/mohammadlohrasbi/health-network.git /root/health-network
cd /root/health-network
chmod +x scripts/*.sh server/*.sh
```

`chmod` لازم است — گیت بیت اجرا را در برخی تنظیمات نگه نمی‌دارد.

**نکته:** `config/.env` معمولاً در `.gitignore` است و با کلون نمی‌آید.
`set-tls.sh` اگر نبود خودش می‌سازد، پس مشکلی پیش نمی‌آید — ولی اگر
مقادیر خاصی در آن دارید، جداگانه کپی کنید.

### اگر از بستهٔ تحویلی استفاده می‌کنید

بستهٔ تحویلی **مخزن کامل نیست** — فایل‌های پایه مثل `deploy-staged.sh`،
`deploy_functions.sh` و `docker-compose-root-ca.yml` در آن نیستند. اگر
پوشهٔ مقصد خالی است، اول مخزن را بگذارید:

```bash
git clone https://github.com/mohammadlohrasbi/health-network.git /root/health-network
```

یا اگر شبکه‌ای در مسیر دیگری دارید و می‌خواهید نسخهٔ تازه‌ای بسازید:

```bash
cp -r /root/health-network /root/health-network
rm -rf /root/health-network/test-tools/bench-runs
```

سپس بسته:

```bash
cd /path/to/health-network-complete
DRY_RUN=1 ./install.sh /root/health-network   # اول نقشه
./install.sh /root/health-network             # اجرای واقعی
```

**`DRY_RUN` چیزی کپی نمی‌کند.** اگر فقط آن را زدید و مستقیم سراغ گام بعد
رفتید، هیچ فایلی نرسیده و همه‌چیز با نسخهٔ قدیمی اجرا می‌شود.

تأیید — این سه باید جواب بدهند:

```bash
ls /root/health-network/scripts/set-tls.sh
ls /root/health-network/scripts/setup-raft.sh
grep -c "_issue_tls" /root/health-network/scripts/network.sh    # > 0
```

و بیت اجرا:

```bash
chmod +x /root/health-network/scripts/*.sh /root/health-network/server/*.sh
```

`config/.env` لازم نیست از قبل باشد — `set-tls.sh` اگر نبود می‌سازدش.

نصب‌کننده فقط کپی می‌کند و از هر فایل جایگزین‌شده پشتیبان می‌گیرد. هیچ
قراردادی تولید نمی‌کند و هیچ‌چیز مستقر نمی‌کند.

---

## مسیر A — نصب کامل از صفر

### گزینهٔ خودکار

```bash
cd /root/health-network/scripts
DRY_RUN=1 ./bootstrap-secure.sh
NODES=3 CHANNELS="datachannel" ./bootstrap-secure.sh
```

کل زنجیره را با ترتیب درست اجرا می‌کند و پیش از پاک کردن شبکهٔ فعلی تأیید
تعاملی می‌خواهد.

هشت گام دارد و هر کدام را با عنوان اعلام می‌کند:

```
━━━ ۰/۷  هم‌راستاسازی مسیرها ━━━
━━━ ۱/۷  مواد رمزنگاری و شبکه پایه ━━━
━━━ ۲/۷  پیکربندی Raft ━━━
━━━ ۳/۷  گواهی‌های TLS ━━━
━━━ ۴/۷  تولید قراردادها ━━━
━━━ ۵/۷  بلوک پیدایش ━━━
━━━ ۶/۷  راه‌اندازی کانتینرها ━━━
━━━ ۷/۷  استقرار کانال‌ها ━━━
```

#### ⚠ اگر جایی متوقف شد

**اسکریپت‌های قبلی را دستی تکرار نکنید.** `bootstrap` با اولین خطا
متوقف می‌شود، و اجرای دوبارهٔ `network.sh` سه دقیقه وقت می‌گیرد،
همه‌چیز را پاک می‌کند، و اگر علت جای دیگری باشد مشکل را حل نمی‌کند.

به‌جای آن، پیام خطای همان گام را بخوانید. هر گام دقیقاً می‌گوید چه چیزی
کم است.

پس از رفع مشکل، `bootstrap` را از ابتدا بزنید. گام یک دوباره اجرا
می‌شود ولی این طبیعی است — `network.sh` هر بار از صفر می‌سازد.

اگر ترجیح می‌دهید هر گام را ببینید، ادامه را دنبال کنید.

### A0 — هم‌راستاسازی مسیرها

چند اسکریپت مخزن مسیر پروژه را **ثابت** در خود دارند:

```bash
source /root/health-network/scripts/channel_contract_map.sh
```

اگر پروژه جای دیگری باشد، این خط به فایلی اشاره می‌کند که وجود ندارد. و
اگر نسخهٔ قدیمی هنوز در مسیر اصلی باشد، فایل **پیدا می‌شود** و اسکریپت با
پیکربندی اشتباه ادامه می‌دهد — که بدتر است.

```bash
cd /root/health-network/scripts
DRY_RUN=1 ./fix-paths.sh      # اول ببینید کدام فایل‌ها
./fix-paths.sh
```

مسیر را از محل خودش مشتق می‌کند، پس نیازی به آرگومان نیست. اجرای مجدد
بی‌ضرر است و از هر فایل تغییریافته پشتیبان می‌گیرد.

`bootstrap-secure.sh` این را خودکار به‌عنوان گام صفر انجام می‌دهد.

### A1 — مواد رمزنگاری و شبکهٔ پایه

**پیش از این گام، CA باید بالا باشد:**

```bash
cd /root/health-network/config
docker compose -f docker-compose-root-ca.yml up -d
sleep 10
docker ps --format '{{.Names}}' | grep -E "rca-main|root-ca"
```

**هر دو باید دیده شوند.** اگر `rca-main` نبود، `network.sh` گواهی نودها را
خودامضا می‌سازد — که برای Raft کشنده است: نودها با TLS pinning یکدیگر را
می‌شناسند و ریشه‌های جدا همدیگر را تأیید نمی‌کنند.

`bootstrap-secure.sh` این را خودکار انجام می‌دهد.

```bash
cd /root/health-network/scripts
NETWORK_TLS=true ORDERER_NODES=3 ./network.sh
```

- `NETWORK_TLS=true` — گواهی TLS برای هر هشت peer و هر orderer، و
  `tlscacerts` در MSP همهٔ سازمان‌ها
- `ORDERER_NODES=3` — هویت و گواهی سه orderer

**گواهی‌ها حتی با `NETWORK_TLS=false` ساخته می‌شوند.** عمدی است: اگر
نمی‌ساخت، روشن کردن TLS بعداً بازسازی کل شبکه را لازم داشت.

**مواد رمزنگاری در `config/crypto-config/` ساخته می‌شوند**، نه در ریشهٔ
پروژه. اگر اسکریپتی گفت «مواد رمزنگاری نیست» در حالی که `network.sh`
موفق بوده، احتمالاً جای اشتباه می‌گردد.

بررسی — هر دو باید جواب بدهند:

```bash
ls config/crypto-config/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/
ls config/crypto-config/ordererOrganizations/example.com/orderers/
```

اولی: `server.crt`، `server.key`، `ca.crt`، `client.crt`، `client.key`.

**و مهم‌تر از وجود گواهی، صادرکنندهٔ آن:**

```bash
cd config/crypto-config/ordererOrganizations/example.com/orderers
for n in orderer orderer2 orderer3; do
  openssl x509 -in $n.example.com/tls/server.crt -noout -issuer
done
```

هر سه باید `issuer=CN = rca-main.example.com` بدهند. اگر کدام‌یک
`issuer` خودش بود، خودامضا است و خوشهٔ Raft کار نخواهد کرد.

دومی باید **به تعداد `ORDERER_NODES`** پوشه نشان دهد. اگر فقط
`orderer.example.com` را دید، متغیر منتقل نشده و خوشهٔ Raft بعداً دو نود
بی‌گواهی خواهد داشت.

### A2 — پیکربندی Raft

```bash
./setup-raft.sh 3
```

`configtx.yaml` را عوض می‌کند و **پس از نوشتن تأیید می‌کند**: نوع اجماع،
تعداد consenter، وجود هر چهار فیلد هر consenter، نسبی بودن مسیر گواهی، و
اینکه `BatchTimeout`، `BatchSize` و `Policies` دست‌نخورده مانده‌اند. اگر
چیزی نخواند، از پشتیبان بازمی‌گرداند و متوقف می‌شود.

پورت رو‌به‌کلاینت هر نود از `docker-compose.yml` خوانده می‌شود نه از فرمول،
تا این دو فایل هرگز از هم جدا نشوند.

بازگشت: `./setup-raft.sh solo`

`configtx.yaml` را به `etcdraft` عوض می‌کند و سه consenter با مسیر
گواهی‌شان اعلام می‌کند. بازگشت: `./setup-raft.sh solo`

### A3 — روشن کردن TLS

```bash
./set-tls.sh on
```

سه کار: یک خط در `config/.env`، فلگ‌های TLS در دستورهای CLI، و drop-in
سرویس داشبورد تا `config.js` ببیند.

**`docker-compose.yml` را لمس نمی‌کند** — خود آن فایل پارامتریک است:

```yaml
- CORE_PEER_TLS_ENABLED=${NETWORK_TLS:-false}
```

### A4 — تولید قراردادها

**از داخل `scripts/` اجرا کنید.** قراردادها در `scripts/chaincode/`
می‌نشینند و `deploy_functions.sh` همان‌جا را می‌گردد.

```bash
cd /root/health-network/scripts
for f in generateChaincodes_part*.sh; do bash "$f"; done
```

اسکریپت مکانی **خودش یک قرارداد را کامپایل می‌کند** و اگر شکست بخورد
متوقف می‌شود. تا `build OK` نبینید جلو نروید.

```bash
ls chaincode | wc -l                                   # 86
grep -l SeedFacilityLayout chaincode/*/chaincode.go | wc -l   # 34
node check-go.js generateChaincodes_hospital.sh         # ✅
```

هر قرارداد دو فایل دارد: `chaincode.go` مختص خودش و `shared.go` که مدل
رادیویی و بازار در آن است. چون همه یک `shared.go` دارند، اگر یکی کامپایل
شود بقیه هم می‌شوند.

### A5 — بلوک پیدایش

```bash
./deploy-staged.sh artifacts

cd ../config
rm -f channel-artifacts/genesis.block
configtxgen -profile OrdererGenesis -channelID system-channel \
  -outputBlock channel-artifacts/genesis.block
cd ../scripts
```

**دو دستور لازم است، نه یکی.** `deploy-staged.sh artifacts` فقط فایل‌های
`.tx` کانال‌ها را می‌سازد؛ بلوک پیدایش را `network.sh` ساخته — و آن پیش از
`setup-raft.sh` اجرا شده، وقتی `configtx.yaml` هنوز `solo` بود.

تأیید:

```bash
cd ../config
configtxgen -inspectBlock channel-artifacts/genesis.block 2>&1 | grep -ci etcdraft
```

**باید عددی بیش از صفر بدهد.** اگر صفر داد، بلوک هنوز `solo` است و orderer
با نوع اجماع اشتباه بالا می‌آید.

**ترتیب اینجا حیاتی است.** بلوک پیدایش هم نوع سرویس ترتیب‌دهی و هم مسیر
گواهی consenter‌ها را در خود دارد، پس باید پس از A2 و A3 ساخته شود.

### A6 — بالا آوردن شبکه

```bash
cd /root/health-network/config
docker compose --profile raft down
docker volume ls -q | grep -E "orderer|peer0" | xargs -r docker volume rm
docker compose --profile raft up -d
docker compose -f docker-compose-root-ca.yml up -d
```

**پاک کردن volumeها هنگام تغییر نوع اجماع لازم است.** اگر orderer در volume
خودش یک system channel پیدا کند می‌گوید «bootstrap نمی‌کنم» و بلوک پیدایش
تازه را نادیده می‌گیرد — یعنی با نوع اجماع قبلی بالا می‌آید.

سه حالت با همان یک فایل:

```bash
docker compose up -d                    # solo
docker compose --profile raft up -d     # سه نود
docker compose --profile raft5 up -d    # پنج نود
```

**profile باید با `configtx.yaml` بخواند.** اگر بلوک پیدایش سه consenter
اعلام کند و فقط یکی بالا بیاید، خوشه رهبر انتخاب نمی‌کند.

```bash
docker logs orderer.example.com 2>&1 | grep -i "leader\|raft" | tail -5
```

تا خط رهبری را نبینید جلو نروید.

### A7 — استقرار کانال‌ها

```bash
cd ../scripts
./deploy-staged.sh channel datachannel
./deploy-staged.sh list
```

**`list` تنها راه مطمئن است.** اسکریپت استقرار حتی با صفر قرارداد commit
شده «موفق» اعلام می‌کند. باید `datachannel  4/4` ببینید.

برای هر بیست کانال — سی تا چهل دقیقه، داخل `tmux`:

```bash
tmux new -s deploy
./deploy-staged.sh all
```

### A8 — بذرکاری چیدمان مرکز درمانی

**اختیاری نیست.** بدون آن هر تراکنش روی سی و چهار قرارداد مکانی با
`no facility layout yet` رد می‌شود.

```bash
./seed-hospital.sh datachannel
```

سی و هفت فراخوانی `SeedFacilityLayout` — یکی به‌ازای هر جفت کانال-قرارداد. چرا
سی و هفت و نه سی و چهار؟ سه قرارداد روی دو کانال‌اند و **هر chaincode در
فابریک فضای حالت مستقل دارد**، پس رجیستری مرکز درمانی مشترک ممکن نیست.

```bash
SEED=7 ./seed-hospital.sh                   # چیدمان دیگر
FACILITIES=24 GRID_M=60000 ./seed-hospital.sh   # شبکهٔ بزرگ‌تر (کاتالوگ را هم به‌روز کنید)
CAPACITY=200 ./seed-hospital.sh             # برای مطالعهٔ کنترل پذیرش
VERIFY_ONLY=1 ./seed-hospital.sh            # فقط گزارش
```

بررسی:

```bash
docker exec -e CORE_PEER_LOCALMSPID=org1MSP \
  -e CORE_PEER_MSPCONFIGPATH=/etc/hyperledger/fabric/admin-msp \
  -e CORE_PEER_ADDRESS=peer0.org1.example.com:7051 \
  -e CORE_PEER_TLS_ENABLED=true \
  -e CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt \
  peer0.org1.example.com peer chaincode query -C datachannel \
  -n LocationBasedAssignment \
  -c '{"function":"ServingCell","Args":["dev-1","3000","4000"]}'
```

باید سلول سرویس‌دهنده، فاصله، RSSI، SINR و ظرفیت شانون برگردد.

### A9 — سرور و ابزارها

```bash
node scripts/update-fn-map.js
bash server/patch-index.sh
systemctl restart dashboard

cd scripts
./install-test-tools.sh
./patch-tls-detect.sh          # ← این سه پیش از خطوط بعد
./patch-tls-paths.sh
node gen-caliper-network.js    # با TLS به grpcs:// می‌رود
./fix-tape-policy.sh
./fix-tape-tls.sh              # گواهی در کانفیگ‌های Tape
./add-test-endpoint.sh         # همه باید ✓ باشند
```

**`patch-tls-detect.sh` باید پیش از دو اسکریپت بعدی بیاید.** `config.js`
وضعیت TLS را از `CORE_PEER_TLS_ENABLED` می‌خواند، و آن متغیر فقط در محیط
سرویس داشبورد ست است. وقتی این اسکریپت‌ها را دستی می‌زنید ست نیست، پس
پیکربندی **بدون TLS** ساخته می‌شود:

- پروفایل Caliper با `grpc://` و بدون `tlsCACerts`
- کانفیگ Tape با `tls_ca_cert` خالی

شبکه TLS دارد، پس هر تراکنش رد می‌شود — **بدون هیچ خطای گواهی، فقط
«۰ موفق از ۵۰۰»**. این وصله `config.js` را وادار می‌کند `config/.env` را
بخواند، همان منبعی که `docker-compose` هم از آن می‌خواند.

بررسی:

```bash
grep -c grpcs ../test-tools/caliper-workspace/networks/connection-profile-org1.json
grep tls_ca_cert ../test-tools/tape-configs/config-datachannel.yaml
```

اولی باید بیش از صفر بدهد؛ دومی مسیر یک فایل موجود. مسیر درست گواهی
سازمان اوردرر این است:

```
config/crypto-config/ordererOrganizations/example.com/msp/tlscacerts/ca-cert.pem
```

**`patch-tls-paths.sh` مسئلهٔ دوم را حل می‌کند:** `config.js` مسیر گواهی را
با نام‌گذاری `cryptogen` می‌سازد
(`.../orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem`)
ولی `network.sh` از `fabric-ca` استفاده می‌کند و ساختار دیگری می‌سازد
(`.../ordererOrganizations/example.com/msp/tlscacerts/ca-cert.pem`). تا وقتی
TLS خاموش بود این مسیر خوانده نمی‌شد؛ حالا Tape سر آن می‌ایستد.

`bootstrap-secure.sh` هر دو وصله را خودکار اعمال می‌کند.

### A10 — امنیت داشبورد

```bash
./secure-dashboard.sh       # رمز را تایپ کنید، paste نکنید
./harden-docker-ports.sh
systemctl restart dashboard
```

---

## مسیر B — به‌روزرسانی شبکهٔ موجود

```bash
cd /path/to/health-network-complete && ./install.sh /root/health-network

cd /root/health-network/scripts
bash generateChaincodes_hospital.sh     # تا build OK
./generateChaincodes_hospital.sh datachannel       # sequence را از شبکه می‌خواند
./seed-hospital.sh datachannel
./patch-tls-detect.sh
./patch-tls-paths.sh
node gen-caliper-assets.js --force
node update-fn-map.js
bash ../server/patch-index.sh
systemctl restart dashboard
```

`--force` ضروری است، وگرنه workloadهای قدیمی آرگومان قدیمی می‌فرستند.

---

## مسیر C — افزودن TLS یا Raft

### فقط TLS

اگر `network.sh` قبلاً گواهی ساخته:

```bash
cd /root/health-network/scripts
./set-tls.sh on
cd ../config && docker compose down && docker compose up -d
cd ../scripts && node gen-caliper-network.js && ./fix-tape-policy.sh
systemctl restart dashboard
```

**بازسازی لازم نیست** — دفتر دست‌نخورده می‌ماند.

اگر گواهی‌ها نیستند، `network.sh` با `NETWORK_TLS=true` لازم است که یعنی
بازسازی.

### افزودن Raft

Raft بازسازی می‌خواهد، چون نوع سرویس ترتیب‌دهی در بلوک پیدایش است:

```bash
./setup-raft.sh 3
./deploy-staged.sh artifacts
cd ../config && docker compose down && docker compose --profile raft up -d
cd ../scripts && ./deploy-staged.sh channel datachannel && ./seed-hospital.sh datachannel
```

---

## فاز تست

### پیش از هر عددی: سیاست تأیید

قراردادها با `OR('org1MSP.member', … ,'org8MSP.member')` مستقرند — **یک
امضا** کافی است. اگر Tape با آستانهٔ بالاتری بسنجد، امضاهایی جمع می‌کند که
شبکه نخواسته و اعدادش مصنوعاً بد می‌شود.

| فایل | آستانه | کاربرد |
|---|---|---|
| `endorsement-any.rego` | ۱ از ۸ | **پیش‌فرض** |
| `endorsement-majority.rego` | ۵ از ۸ | فرضی؛ در گزارش برچسب بخورد |

```bash
./fix-tape-policy.sh            # مطابق استقرار
./fix-tape-policy.sh majority   # فرضی
```

اثرش را بدانید: baseline قدیمی با ۵از۸ حدود ۶۶ tps بود؛ با سیاست درست
همان بار **۱۱۲ tps** شد.

### از رابط وب

مرورگر → `https://IP-سرور` → ورود → **Benchmark**

چهار انتخاب مستقل:

**دامنه** — یک قرارداد، یک کانال، چند کانال، دستچین، کل شبکه. هشتاد و نه
هدف پیش‌فرض؛ تنها استثنا `GetPolicy` که تابع نوشتنی ندارد.

**عملیات بازار** — «Add market operations» یا «Market operations only».
با بازار، هشتاد و نه هدف به دویست و هفتاد و چهار می‌رسد.

**ابزار** — دو تب مجزا.

**هم‌زمانی** — «Targets at once». یک یعنی هر هدف در انزوا؛ بیشتر یعنی چند
کانال با هم زیر بار، که به شبکهٔ واقعی نزدیک‌تر است.

### هم‌زمانی و متریکی که فقط آنجا معنا دارد

با هم‌زمانی بیش از یک، کارت **Network aggregate** ظاهر می‌شود. دو عدد جدا
ثبت می‌شود: مجموع نرخ اهداف، و گذردهی واقعی شبکه در زمان دیواری آن موج.

**فاصلهٔ این دو، خودِ اندازه‌گیری است.** اگر شبکه مقیاس بپذیرد مجموع با
پهنای موج بالا می‌رود؛ اگر اشباع شود صاف می‌ماند در حالی که نرخ هر هدف
پایین می‌آید.

حافظه: Tape سبک است و تا هشت هدف هم‌زمان مشکلی ندارد؛ Caliper با دو worker
هر هدف، بیش از سه هدف هم‌زمان روی سرور شما احتمالاً OOM می‌دهد. با دو شروع
کنید و `free -m` را نگاه کنید.

### ترتیب پیشنهادی برای اولین اعداد

```
۱. یک قرارداد، Tape، ۱۰۰۰ تراکنش
۲. همان، Caliper، ۵۰۰ با نرخ ۲۰
۳. کل datachannel — چهار قرارداد
۴. auditchannel — هفت قرارداد، تمیزترین پایه
۵. کل شبکه، ۸۹ هدف
```

اگر گام یک خطا داد، مشکل در استقرار است نه بنچمارک.

---

## آنچه باید دربارهٔ اعداد بدانید

### Tape تأخیر گزارش نمی‌کند

خروجی واقعی Tape فقط گذردهی و تعداد بلاک دارد. ستون تأخیر `n/r` است، نه
صفر. **Tape سقف گذردهی می‌دهد، Caliper تأخیر.**

### تأخیر شما گلوگاه شبکه نیست

`BatchTimeout=2s` و `MaxMessageCount=500`. در نرخ بیست، هر بازهٔ تایم‌اوت
فقط چهل تراکنش می‌گیرد — بسیار کمتر از پانصد. پس بلاک **همیشه با تایم‌اوت
بسته می‌شود**:

```
۱۰۰۰ms انتظار بلاک + ۴۰۰ms تأیید و کامیت ≈ ۱۴۰۰ms
اندازه‌گیری واقعی                          = ۱۴۷۰ms
```

نقطهٔ گذار: `۵۰۰ ÷ ۲ = ۲۵۰ tps`. زیر آن تأخیر ثابت است؛ با بالا رفتن نرخ
تأخیر **کاهش** می‌یابد چون بلاک زودتر پر می‌شود. نمودار تأخیر بر حسب نرخ
با آن کمینه، احتمالاً بهترین شکل فصل ارزیابی است.

### رد شدن همیشه خطا نیست

| پیام | خطاست؟ |
|---|---|
| `out of coverage: SINR below threshold` | ❌ خروجی مدل |
| `cell is saturated` | ❌ خروجی مدل |
| `no spectrum left` | ❌ خروجی مدل |
| `relaying gains nothing` | ❌ خروجی مدل |
| `seed does not match` | ✅ خطا |
| `no facility layout yet` | ✅ خطا |
| `MVCC_READ_CONFLICT` | ⚠️ بستگی دارد |

`RelayFor` حدود پنجاه و سه درصد پذیرش دارد — بقیه رد واقعی‌اند چون
سایه‌فرسایی جای رله را بهتر از کاربر نکرده. **در گزارش نرخ پذیرش را جدا از
نرخ خطا بیاورید.**

### مقایسه‌های نامعتبر

اعداد پیش و پس از بازنویسی قراردادها؛ Tape و Caliper به‌عنوان دو
اندازه‌گیری از یک چیز؛ سیاست‌های تأیید متفاوت؛ بذرهای متفاوت؛ اجراهای
تک‌باره بدون تکرار.

پراکندگی پایهٔ Tape حدود **هفت درصد** است. هر تفاوتی کمتر از این معنادار
نیست.

---

## عیب‌یابی

### استقرار

| نشانه | علت | اصلاح |
|---|---|---|
| `directory not found: scripts/chaincode/X` | قراردادها در محل اشتباه | از `scripts/` بازتولید کنید |
| `undefined: ...` هنگام build | خطای کامپایل | `node check-go.js` سپس `go build` |
| `0/4 قرارداد commit شده` | کامپایل شکست خورده | خروجی build را بخوانید |
| `KeyError: ContainerConfig` | compose نسخهٔ یک | `docker compose` |

### راه‌اندازی از صفر

خطاهایی که در عمل دیده شده‌اند و علت واقعی‌شان:

| نشانه | علت | اصلاح |
|---|---|---|
| `✗ <اسکریپت> نیست` در بررسی پیش‌نیاز | بسته نصب نشده یا با `DRY_RUN` اجرا شده | `./install.sh /root/health-network` بدون `DRY_RUN` |
| `✗ مواد رمزنگاری orderer اصلی نیست` بعد از یک `network.sh` موفق | اسکریپت در مسیر اشتباه می‌گردد | نسخهٔ جدید `setup-raft.sh` |
| `Permission denied` روی اسکریپت | بیت اجرا از گیت نیامده | `chmod +x scripts/*.sh` |
| `channel_contract_map.sh: No such file` | اسکریپت مخزن مسیر قدیمی را کد کرده | `./fix-paths.sh` |
| `.env نیست` | با کلون نمی‌آید یا `install.sh` قدیمی است | نسخهٔ جدید `set-tls.sh` خودش می‌سازد |
| فقط یک پوشهٔ orderer ساخته شد | `ORDERER_NODES` منتقل نشده | `NETWORK_TLS=true ORDERER_NODES=3 ./network.sh` |
| پوشهٔ `tls/` خالی است | `network.sh` قدیمی است | `grep -c _issue_tls scripts/network.sh` باید بیش از صفر باشد |
| `mount ... not a directory` | داکر به‌جای فایل گم‌شده پوشه ساخته | آن مسیر را `rm -rf` کنید |

**تشخیص سریع پیش از هر اجرا:**

```bash
cd /root/health-network
ls config/.env                                    # باید باشد
grep -c "_issue_tls" scripts/network.sh           # باید > 0
ls scripts/set-tls.sh scripts/setup-raft.sh       # هر دو
```

اگر هرکدام جواب نداد، نصب کامل نشده و ادامه دادن فقط همان خطاها را
تکرار می‌کند.

### Raft

| نشانه | علت | اصلاح |
|---|---|---|
| رهبر انتخاب نمی‌شود | profile با configtx نمی‌خواند | `--profile raft` با `setup-raft.sh 3` |
| `refers to undefined network` | نسخهٔ قدیمی `setup-raft.sh` سرویس تزریق می‌کرد | نسخهٔ جدید — profile را به کار می‌برد |
| `no TLS certificate` | گواهی خوشه نیست | `NETWORK_TLS=true ORDERER_NODES=3 ./network.sh` |
| `tls: bad certificate` بین اوردررها | گواهی‌ها ریشهٔ مشترک ندارند | بررسی `issuer` هر سه — همه باید `rca-main` باشند |
| `consenter ... has invalid certificate: signed by unknown authority` | `tlscacerts` گواهی ریشه را دارد ولی امضاکننده `rca-main` است | نسخهٔ جدید `network.sh` زنجیرهٔ کامل می‌نویسد |
| `container exited with 0` + `handshake ... server=ChaincodeServer` | بیلدر خارجی `CORE_PEER_TLS_ENABLED=false` را ثابت داشت | نسخهٔ جدید `scripts/builders/golang/bin/run` |
| `builder 'prebuilt' run failed: exit status 127` | بیلدر داخل کانتینر peer اجرا می‌شود و آنجا `python3`/`jq` نیست | همان — نسخهٔ جدید فقط `sed` به کار می‌برد |
| بیلدر پس از هر `bootstrap` یا `network.sh` به نسخهٔ بدون TLS برمی‌گردد | `network.sh` تابع `setup_external_builders` دارد که فایل `run` را از heredoc داخلی خودش **بازمی‌نویسد** | نسخهٔ جدید `network.sh` — heredoc اصلاح شده؛ کپی دستی فایل `run` کافی نیست |
| بیلدر پس از `git pull` یا `install.sh` عوض نمی‌شود | نسخهٔ قدیمی `install.sh` زیرپوشه‌ها را کپی نمی‌کرد | `install.sh` جدید بازگشتی کپی می‌کند |
| `tls: certificate required` هنگام `logSendFailure` | listener جدای خوشه گواهی کلاینت نمی‌فرستد | در compose جدید listener جدا برداشته شده؛ خوشه از TLS عمومی ارث می‌برد |
| `client didn't provide a certificate` از هشت IP | خوشهٔ Raft روی پورت عمومی است، پس آن پورت از هر کلاینتی گواهی می‌خواهد | `CORE_PEER_TLS_CLIENTCERT_FILE` در compose و `--clientauth` در CLI — هر دو در نسخهٔ جدید |
| `consensus type: solo` با وجود `etcdraft` در configtx | بلوک پیدایش قدیمی در volume | volumeها را پاک کنید و بلوک را از نو بسازید |
| انتخابات بی‌پایان، هر نود ۱ رأی | رأی‌ها رد و بدل نمی‌شوند | همان mTLS خوشه |
| `Failed to get user: sql: no rows in result set` | اوردررهای Raft در CA ثبت‌نام نشده‌اند | نسخهٔ جدید `network.sh` — هویت‌ها را در پیکربندی CA می‌سازد |
| `Authentication failure` هنگام enroll | همان بالا | همان — و **بازسازی کامل لازم است**، چون هویت‌ها فقط هنگام ساخت CA تعریف می‌شوند |
| رهبر انتخاب نمی‌شود با وجود ۳ نود بالا | همان بالا | CA را بالا بیاورید و گواهی‌ها را بازسازی کنید |
| اوردررها همدیگر را نمی‌بینند | پورت ۷۰۵۳ | `docker logs` هر نود |
| `cacerts` پیدا نشد هنگام `configtxgen` | `crypto-config` ناقص است | `network.sh` را کامل اجرا کنید |

### TLS

| نشانه | علت | اصلاح |
|---|---|---|
| `tls: bad certificate` | گواهی و ریشه نمی‌خوانند | `network.sh` با `NETWORK_TLS=true` |
| `unable to load orderer.tls.rootcert.file` | مسیر گواهی orderer از دید کانتینر peer غلط بود | نسخهٔ جدید `docker-compose.yml` و `set-tls.sh` |
| `genesis block file not found` پس از خطای بالا | آبشاری است — کانال اصلاً ساخته نشده | ابتدا خطای اول را رفع کنید |
| `number of peer addresses (8) does not match the number of TLS root cert files (1)` | با TLS هر `--peerAddresses` یک گواهی می‌خواهد | `./set-tls.sh on` نسخهٔ جدید |
| `DeadlineExceeded ... RST_STREAM` هنگام approve | مهلت ۳۰ ثانیه با Raft و TLS کم است | `./set-tls.sh on` مهلت را ۳۰۰ ثانیه می‌کند |
| CLI بی‌پاسخ | فلگ TLS ندارد | `./set-tls.sh on` دوباره |
| Caliper ۰ موفق از N، بدون خطای گواهی | پروفایل با `grpc://` و بدون `tlsCACerts` ساخته شده | `./patch-tls-detect.sh` سپس `node gen-caliper-network.js` |
| Tape: `fail to load TLS CA Cert ... tlsca.example.com-cert.pem` | `config.js` نام‌گذاری cryptogen دارد ولی شبکه با fabric-ca ساخته شده | `./patch-tls-paths.sh` سپس `./fix-tape-policy.sh` |
| کانفیگ‌های Tape `tls_ca_cert: ""` دارند | `install-test-tools.sh` آنها را برای شبکهٔ plaintext ساخته | `./fix-tape-tls.sh` — بدون نصب دوبارهٔ ابزارها |
| اسکریپت دستی پیکربندی بدون TLS می‌سازد ولی سرویس درست کار می‌کند | `CORE_PEER_TLS_ENABLED` فقط در محیط سرویس ست است | `./patch-tls-detect.sh` — `config.js` را وادار می‌کند `.env` را بخواند |

### داشبورد

| نشانه | علت | اصلاح |
|---|---|---|
| `403 Forbidden` | `.htpasswd` نیست | `htpasswd -c /etc/nginx/auth/.htpasswd USER` |
| ریدایرکت به `localhost` | nginx از `$server_name` استفاده می‌کند | به `$host` عوض کنید |
| `/api/bench` خطای ۵۰۰ | js-yaml نصب نیست | `cd server && npm install js-yaml` |

### بنچمارک

| نشانه | علت | اصلاح |
|---|---|---|
| `could not determine executable` | باینری Caliper در PATH سرویس نیست | `CALIPER_BIN` را ست کنید |
| `ENOTEMPTY` هنگام نصب | نصب سراسری نیمه‌کاره | `rm -rf $(npm root -g)/@hyperledger/caliper-cli*` |
| `too_many_pings` | همهٔ تراکنش‌ها رد شده‌اند | اول خطای chaincode را بخوانید |
| `cannot be benchmarked with Tape` | رفتار درست | از Caliper استفاده کنید |

### اگر چیزی جا افتاده

```bash
./scripts/add-test-endpoint.sh
```

خروجی این اسکریپت بهترین نقطهٔ شروع برای گزارش مشکل است.

---

## نگه‌داری

**پس از هر reboot:**

```bash
cd /root/health-network/config
docker compose --profile raft up -d
docker compose -f docker-compose-root-ca.yml up -d
systemctl start dashboard
```

**پس از هر `git pull`:** `bash server/patch-index.sh`

**اگر واقعاً از صفر می‌خواهید:** `network.sh` کانتینرها و volumeها را پاک
می‌کند ولی شبکهٔ داکر را نه. برای پاک‌سازی کامل:

```bash
docker network rm health-network 2>/dev/null
```

**پاک‌سازی دیسک:** `go clean -cache` و `docker image prune -f` امن‌اند.
**هرگز `docker volume prune` یا `docker compose down -v` نزنید** — دفتر
کانال‌ها در volumeهاست.

**پیش از هر تغییر بزرگ:**

```bash
cp -r /root/health-network/test-tools/bench-runs ~/bench-backup-$(date +%F)
cd /root/health-network && git add -A && git commit -m "working state"
```

---

## اسناد مرجع

| سند | محتوا |
|---|---|
| `docs/benchmark-guide.md` | Caliper و Tape: نحوهٔ کار، ساختار، یازده آزمایش با پیش‌بینی |
| `docs/market-guide.md` | بازار داد و ستد: چهار بازار، تقسیم موجودی، توپولوژی پول |
| `docs/resource-management.md` | طیف، انرژی، توان، بازاستفاده فرکانسی |
| `docs/network-roles.md` | نقش هر قرارداد و کانال در شبکه |
| `docs/architecture-guide.md` | معماری، خانواده‌های داده، دلالت‌های ارزیابی |
| `docs/contract-inventory.md` | فهرست هشتاد و شش قرارداد |
| `reference/clinical.go` | هستهٔ رادیویی با توضیح هر تصمیم طراحی |

---

## دو هشدار صادقانه

**اسکریپت‌های TLS و Raft روی فابریک واقعی آزموده نشده‌اند.** ساختار
فایل‌ها، رفت‌وبرگشت پیکربندی و ترتیب اجرا کامل آزموده شده، ولی اینکه خوشهٔ
Raft با این گواهی‌ها رهبر انتخاب کند فقط روی سرور شما معلوم می‌شود. گام A6
نقطهٔ حقیقت است.

**`deploy-staged.sh` حتی با صفر قرارداد commit شده «موفق» اعلام می‌کند.**
این باگ در اسکریپت خودِ مخزن است. `./deploy-staged.sh list` را بعد از هر
استقرار بزنید — تنها راه مطمئن همین است.
