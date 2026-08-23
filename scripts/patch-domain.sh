#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# patch-domain.sh — پاک‌سازی ارجاعات باقی‌مانده دامنه 6G
#
# port-from-6g.sh زیرساخت را منتقل می‌کند و لایه قرارداد را عوض
# می‌کند، ولی چند فایل هنوز واژگان رادیویی دارند: نگاشت عملیات
# دمو در fabric.js، رشته‌های تشخیص خطای بذرکاری در bench-runner.js،
# نام پارامترها در gen-caliper-assets.js و برچسب‌های رابط کاربری.
#
# این‌ها را جدا کردم چون ماهیتاً متفاوت‌اند: port یک انتقال
# ساختاری است، این یک ترجمه واژگانی. اگر با هم بودند، هر بار که
# برچسبی عوض می‌شد باید کل انتقال دوباره اجرا می‌شد.
#
# اجرای دوباره امن است.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DRY_RUN="${DRY_RUN:-0}"

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
warn() { echo "[$(date +'%H:%M:%S')] هشدار: $*" >&2; }

if [ "$DRY_RUN" != "1" ]; then
  BK="$ROOT_DIR/.domain-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK"
fi

edit() { # edit <file> <sed-expr...>
  # rel را **پیش از** shift نگه می‌داریم. نسخه اول این کار را
  # نمی‌کرد و پس از shift از $1 برای مسیر پشتیبان استفاده می‌شد —
  # یعنی نام فایل پشتیبان در واقع اولین عبارت sed بود. تا وقتی
  # عبارت‌ها کوتاه بودند یک مسیر عجیب ولی معتبر می‌ساخت و بی‌صدا
  # می‌گذشت؛ اولین عبارت بلند با «File name too long» شکست.
  local rel="$1"
  local f="$ROOT_DIR/$rel"; shift
  [ -f "$f" ] || { warn "غایب: $rel"; return 0; }
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry] $rel"
    return 0
  fi
  mkdir -p "$BK/$(dirname "$rel")"
  cp "$f" "$BK/$rel"
  for e in "$@"; do sed -i "$e" "$f"; done
}

# ── ۱. fabric.js — نگاشت عملیات دمو هر کانال ────────────
# این نگاشت چیزی است که دکمه «ثبت نمونه» در داشبورد صدا می‌زند.
# اگر قراردادهای 6G در آن بماند، هر کلیک خطای «chaincode یافت نشد»
# می‌دهد. با node بازنویسی می‌شود چون بلوک چندخطی است.
if [ "$DRY_RUN" != "1" ]; then
  log "بازنویسی CHANNEL_TEST_FN در fabric.js"
  cp "$ROOT_DIR/server/fabric.js" "$BK/server/fabric.js" 2>/dev/null || \
    { mkdir -p "$BK/server"; cp "$ROOT_DIR/server/fabric.js" "$BK/server/fabric.js"; }
  node - "$ROOT_DIR" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const p = path.join(root, 'server', 'fabric.js');
let src = fs.readFileSync(p, 'utf8');

// یک قرارداد نماینده برای هر کانال — عمداً از نوع ledger یا guarded
// انتخاب شده‌اند نه selector، چون دکمه دمو نباید به علائم حیاتی
// نیاز داشته باشد. RequestAdmission سیزده پارامتر می‌گیرد؛
// AppendProgressNote سه تا.
const BLOCK = `const CHANNEL_TEST_FN = {
  patientchannel:    { chaincode: 'RegisterPatient',       fn: 'RegisterPatient',       buildArgs: (id, d = {}) => [id, String(d.subject ?? 'commit-demo'), String(d.detail ?? 'ثبت اولیه')] },
  clinicalchannel:   { chaincode: 'AppendProgressNote',    fn: 'AppendProgressNote',    buildArgs: (id, d = {}) => [id, String(d.subject ?? 'patient-demo'), String(d.detail ?? 'یادداشت پیشرفت')] },
  admissionchannel:  { chaincode: 'DischargePatient',      fn: 'DischargePatient',      buildArgs: (id, d = {}) => [id, String(d.subject ?? 'patient-demo'), String(d.detail ?? 'ترخیص')] },
  bedchannel:        { chaincode: 'ReportBedCensus',       fn: 'ReportBedCensus',       buildArgs: (id, d = {}) => [id, String(d.subject ?? 'facility-1'), String(d.detail ?? 'سرشماری تخت')] },
  surgerychannel:    { chaincode: 'RecordSurgicalOutcome', fn: 'RecordSurgicalOutcome', buildArgs: (id, d = {}) => [id, String(d.subject ?? 'case-demo'), String(d.detail ?? 'نتیجه جراحی')] },
  equipmentchannel:  { chaincode: 'RegisterDevice',        fn: 'RegisterDevice',        buildArgs: (id, d = {}) => [id, String(d.subject ?? 'device-demo'), String(d.detail ?? 'ثبت دستگاه')] },
  pharmacychannel:   { chaincode: 'RegisterDrugBatch',     fn: 'RegisterDrugBatch',     buildArgs: (id, d = {}) => [id, String(d.subject ?? 'batch-demo'), String(d.detail ?? 'ثبت بچ')] },
  bloodchannel:      { chaincode: 'RegisterBloodUnit',     fn: 'RegisterBloodUnit',     buildArgs: (id, d = {}) => [id, String(d.subject ?? 'unit-demo'), String(d.detail ?? 'ثبت واحد خون')] },
  labchannel:        { chaincode: 'RecordLabResult',       fn: 'RecordLabResult',       buildArgs: (id, d = {}) => [id, String(d.subject ?? 'order-demo'), String(d.detail ?? 'نتیجه آزمایش')] },
  imagingchannel:    { chaincode: 'RecordImagingReport',   fn: 'RecordImagingReport',   buildArgs: (id, d = {}) => [id, String(d.subject ?? 'study-demo'), String(d.detail ?? 'گزارش تصویربرداری')] },
  staffchannel:      { chaincode: 'RegisterStaff',         fn: 'RegisterStaff',         buildArgs: (id, d = {}) => [id, String(d.subject ?? 'staff-demo'), String(d.detail ?? 'ثبت کارکنان')] },
  referralchannel:   { chaincode: 'AcceptReferral',        fn: 'AcceptReferral',        buildArgs: (id, d = {}) => [id, String(d.subject ?? 'ref-demo'), String(d.detail ?? 'پذیرش ارجاع')] },
  emergencychannel:  { chaincode: 'ReleaseAmbulance',      fn: 'ReleaseAmbulance',      buildArgs: (id, d = {}) => [id, String(d.subject ?? 'amb-demo'), String(d.detail ?? 'آزادسازی آمبولانس')] },
  insurancechannel:  { chaincode: 'RecordCoveragePolicy',  fn: 'RecordCoveragePolicy',  buildArgs: (id, d = {}) => [id, String(d.subject ?? 'policy-demo'), String(d.detail ?? 'ثبت پوشش')] },
  supplychannel:     { chaincode: 'ReportStockLevel',      fn: 'ReportStockLevel',      buildArgs: (id, d = {}) => [id, String(d.subject ?? 'item-demo'), String(d.detail ?? 'سطح موجودی')] },
  marketchannel:     { chaincode: 'MintResourceToken',     fn: 'MintResourceToken',     buildArgs: (id, d = {}) => [String(d.owner ?? id), String(d.amount ?? 1000)] },
  consentchannel:    { chaincode: 'GrantConsent',          fn: 'GrantConsent',          buildArgs: (id, d = {}) => [id, String(d.subject ?? 'commit-demo'), String(d.detail ?? 'اعطای رضایت')] },
  auditchannel:      { chaincode: 'LogSystemAudit',        fn: 'LogSystemAudit',        buildArgs: (id, d = {}) => [id, String(d.subject ?? 'system'), String(d.detail ?? 'تغییر پیکربندی')] },
  compliancechannel: { chaincode: 'ReportIncident',        fn: 'ReportIncident',        buildArgs: (id, d = {}) => [id, String(d.subject ?? 'incident-demo'), String(d.detail ?? 'گزارش رخداد')] },
  analyticschannel:  { chaincode: 'ReportOccupancy',       fn: 'ReportOccupancy',       buildArgs: (id, d = {}) => [id, String(d.subject ?? 'facility-1'), String(d.detail ?? 'اشغال')] },
};`;

const re = /const CHANNEL_TEST_FN\s*=\s*\{[\s\S]*?\n\};/;
if (!re.test(src)) {
  console.error('  هشدار: بلوک CHANNEL_TEST_FN پیدا نشد');
} else {
  src = src.replace(re, BLOCK);
  src = src.replace(
    /\/\/ انتخاب‌ها: تابع نوشتنی بدون وابستگی به رکورد آنتنِ از قبل موجود \(blind write\)\./,
    '// انتخاب‌ها عمداً از نوع ledger یا guarded هستند نه selector:\n'
    + '// دکمه دمو نباید سیزده پارامتر علائم حیاتی بخواهد.');
  fs.writeFileSync(p, src);
  console.log('  fabric.js بازنویسی شد');
}

// اعتبارسنجی: هر chaincode نام‌برده باید واقعاً روی همان کانال باشد.
// در 6G نگاشتی که با کانال نمی‌خواند تا زمان اولین کلیک پنهان ماند.
const { CHANNEL_CHAINCODE_MAP } = require(path.join(root, 'server', 'contract-fn-map.js'));
const { CONTRACT_FN } = require(path.join(root, 'server', 'contract-fn-map.js'));
const body = fs.readFileSync(p, 'utf8');
const block = re.exec(body)[0];
const rows = [...block.matchAll(/(\w+channel):\s*\{\s*chaincode:\s*'([^']+)',\s*fn:\s*'([^']+)'/g)];
let bad = 0;
for (const [, ch, cc, fn] of rows) {
  if (!(CHANNEL_CHAINCODE_MAP[ch] || []).includes(cc)) {
    console.error(`  ✗ ${cc} روی ${ch} مستقر نیست`); bad++;
  } else if (!CONTRACT_FN[cc] || CONTRACT_FN[cc].fn !== fn) {
    console.error(`  ✗ تابع ${fn} با امضای ${cc} نمی‌خواند`); bad++;
  }
}
if (bad) process.exit(1);
console.log(`  ✓ هر ${rows.length} نگاشت با کانال و امضا می‌خواند`);
NODEEOF
fi

# ── ۲. bench-runner.js — تشخیص خطای بذرکاری ─────────────
# قرارداد سلامت پیام دیگری می‌دهد. اگر این رشته‌ها به‌روز نشوند،
# داشبورد «بذرکاری نشده» را به عنوان خطای ناشناخته گزارش می‌کند و
# شما دنبال باگ شبکه می‌گردید.
log "به‌روزرسانی تشخیص خطای بذرکاری در bench-runner.js"
# رشته الگو خودش | دارد، پس جداکننده sed را # می‌گیریم.
edit server/bench-runner.js \
  's#SeedNetwork first.no antennas registered.no antenna layout#SeedFacilityLayout|بذرکاری نشده|هیچ مرکزی بذرکاری نشده#g' \
  's#has no antenna layout — run scripts/seed-network.sh#چیدمان مراکز ندارد — scripts/seed-hospital.sh را اجرا کنید#g' \
  's#A spatial contract refuses every write until its antenna layout#قرارداد selector تا وقتی چیدمان مراکز نداشته باشد هر نوشتنی را رد می‌کند#g'

# ── ۳. gen-caliper-assets.js — نام پارامترها ────────────
log "به‌روزرسانی نام پارامترها در gen-caliper-assets.js"
edit scripts/gen-caliper-assets.js \
  "s|const SHARED_REF = new Set(\['antennaID'\]);|const SHARED_REF = new Set(['facilityID']);|" \
  "s|'entityID', 'deviceID', 'userID', 'networkID', 'antennaID',|'id', 'subject', 'patientCommit', 'facilityID', 'unitID', 'claimID',|" \
  "s|if (SHARED_REF.has(p)) return 'antenna-1';|if (SHARED_REF.has(p)) return 'facility-1';|" \
  's|need a seeded antenna|به چیدمان بذرکاری‌شده مراکز نیاز دارند|' \
  's|Regions derived from the seed-42 antenna layout: the edge sits in the|نواحی از چیدمان بذر seed-1404 مراکز مشتق شده‌اند|'

# ── ۴. scenario-routes.js — نام میدان ───────────────────
# antennaDep دیگر در contract-fn-map وجود ندارد؛ بدون این تغییر
# هر قرارداد `available: false` می‌شود و صفحه سناریو خالی می‌ماند.
log "به‌روزرسانی scenario-routes.js"
edit server/scenario-routes.js \
  's|available: !!meta \&\& !meta.antennaDep,|available: !!meta \&\& !meta.readOnly,|' \
  "s|reason: !meta ? 'no-write-fn' : meta.antennaDep ? 'antenna-dependent' : null,|reason: !meta ? 'no-write-fn' : meta.readOnly ? 'read-only' : null,|" \
  's|فرستنده‌ها = آنتن‌های ماکروسل و IoT ها؛ گیرنده‌ها = کاربران.|مراکز درمانی و بیماران؛ ارجاع بر پایه زمان سفر و توانمندی.|' \
  's|فرستنده‌ها: آنتن‌های ماکروسل + IoT ها؛ گیرنده‌ها: کاربران|مراکز درمانی و بیماران|' \
  's|antennas: topology.antennas,|facilities: topology.facilities,|' \
  's|محدوده هر آنتن: موقعیت + تعداد زیرمجموعه‌ها|حوزه هر مرکز: موقعیت + تعداد ارجاع|'

# ── ۵. test-app.js — برچسب‌های رابط ─────────────────────
log "به‌روزرسانی برچسب‌های test-app.js"
edit public/test-app.js \
  "s|' — needs an antenna record'|' — نیازمند بذرکاری مراکز'|" \
  's|antennaDep|needsSeed|g' \
  "s|'Reads an antenna record before writing — seed one or it will not commit'|'پیش از نوشتن چیدمان مراکز را می‌خواند — بدون بذرکاری commit نمی‌شود'|" \
  "s|' · needs antenna'|' · نیازمند بذر'|"

# ── ۶. app.js — نگاشت کانال ─────────────────────────────
if [ "$DRY_RUN" != "1" ]; then
  log "بازنویسی نگاشت کانال در app.js"
  mkdir -p "$BK/public"; cp "$ROOT_DIR/public/app.js" "$BK/public/app.js"
  node - "$ROOT_DIR" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const { CHANNEL_CHAINCODE_MAP } =
  require(path.join(root, 'server', 'contract-fn-map.js'));
const p = path.join(root, 'public', 'app.js');
let src = fs.readFileSync(p, 'utf8');

// نگاشت سمت مرورگر باید با سمت سرور یکی باشد، وگرنه کاربر
// کانالی را می‌بیند که وجود ندارد.
const re = /(const\s+\w*CHANNEL\w*\s*=\s*)\{[\s\S]*?\n\};/;
if (re.test(src)) {
  src = src.replace(re, (m, head) =>
    head + JSON.stringify(CHANNEL_CHAINCODE_MAP, null, 2) + ';');
  fs.writeFileSync(p, src);
  console.log('  app.js نگاشت کانال به‌روز شد');
} else {
  console.error('  هشدار: نگاشت کانال در app.js پیدا نشد — دستی بررسی کنید');
}
NODEEOF
fi

# شناسه‌های نمایشی
edit public/app.js \
  "s#a.entityID || a.deviceID || a.userID || a.networkID || a.antennaID || a.policyID#a.id || a.ID || a.subject || a.facility || a.contract#" \
  "s#'entityID','deviceID','userID','networkID','antennaID','policyID'#'id','ID','subject','contract','facility','payload'#"

# ── ۷. ارجاع به فایل نقشه ───────────────────────────────
log "به‌روزرسانی ارجاع نقشه در HTML"
for f in public/scenario.html public/dashboard.html public/index.html public/test.html; do
  edit "$f" \
    's|coverage-map\.js|catchment-map.js|g' \
    's|renderCoverage|renderCatchment|g'
done
edit public/scenario-app.js \
  's|renderCoverage|renderCatchment|g' \
  's|topology\.antennas|topology.facilities|g' \
  's|\.iots\b|.patients|g' \
  's|آنتن|مرکز|g' \
  's|antenna|facility|g'

# ── ۸. عنوان و متن صفحات ────────────────────────────────
log "به‌روزرسانی عنوان صفحات"
for f in public/index.html public/dashboard.html public/scenario.html \
         public/test.html public/explorer.html public/home.js; do
  edit "$f" \
    's|شبکه 6G|شبکه ملی سلامت|g' \
    's|شبکه‌های 6G|شبکه ملی سلامت|g' \
    's|6G Network|Health Network|g' \
    's|مدیریت شبکه سلولی|مدیریت شبکه سلامت|g'
done


# ── ۹. دور دوم: مواردی که با گشت اول جا ماندند ─────────
# این‌ها را با اجرای grep روی درخت پس از دور اول پیدا کردم. اگر
# نبودند، دکمه دود-تست کانال‌های ناموجود را صدا می‌زد و صفحه اصلی
# روی میدان topology.antennas خطای undefined می‌داد.
log "دور دوم: بازمانده‌ها"

edit public/home.js \
  "s#(t.antennas || \[\])#(t.facilities || [])#" \
  's#sumMacro#sumFacility#g'

edit server/bench-routes.js \
  "s#Location-aware contracts pick their own serving cell, so the antenna layout must exist before they accept a write. Run scripts/seed-network.sh once after upgrading.#قراردادهای selector مرکز مقصد را خودشان انتخاب می‌کنند، پس چیدمان مراکز باید پیش از پذیرش هر نوشتنی موجود باشد. یک بار scripts/seed-hospital.sh را اجرا کنید.#"

edit scripts/bootstrap-secure.sh \
  's#بذرکاری چیدمان آنتن#بذرکاری چیدمان مراکز#g' \
  's#seed-network\.sh#seed-hospital.sh#g' \
  's#generateChaincodes_spatial\.sh#generateChaincodes_hospital.sh#g' \
  's#upgrade-spatial\.sh#generateChaincodes_hospital.sh#g'

edit public/test.html \
  's#includeAntennaDep#includeSeedDep#g' \
  's#Include contracts that need a seeded antenna record#شامل قراردادهایی که به چیدمان بذرکاری‌شده مراکز نیاز دارند#'

edit public/test-app.js \
  's#includeAntennaDep#includeSeedDep#g'

# install-test-tools.sh دود-تست هر کانال را با یک قرارداد نمونه
# می‌زند. با کانال‌های 6G در آن، هر اجرا بیست خطای «کانال یافت
# نشد» می‌داد و کاربر فکر می‌کرد شبکه خراب است.
if [ "$DRY_RUN" != "1" ] && [ -f "$ROOT_DIR/scripts/install-test-tools.sh" ]; then
  log "بازنویسی دود-تست در install-test-tools.sh"
  mkdir -p "$BK/scripts"; cp "$ROOT_DIR/scripts/install-test-tools.sh" "$BK/scripts/"
  node - "$ROOT_DIR" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const p = path.join(root, 'scripts', 'install-test-tools.sh');
let src = fs.readFileSync(p, 'utf8');

// از fabric.js می‌خوانیم تا دود-تست و دکمه دمو هرگز واگرا نشوند.
const fab = fs.readFileSync(path.join(root, 'server', 'fabric.js'), 'utf8');
const block = /const CHANNEL_TEST_FN\s*=\s*\{[\s\S]*?\n\};/.exec(fab)[0];
const rows = [...block.matchAll(
  /(\w+channel):\s*\{\s*chaincode:\s*'([^']+)',\s*fn:\s*'([^']+)'/g)];

const ccMap = rows.map(([, ch, cc]) => `    ["${ch}"]="${cc}"`).join('\n');
const fnMap = rows.map(([, ch, , fn]) =>
  `    ["${ch}"]="${fn}|smoke-$$|smoke|dry-run"`).join('\n');

let n = 0;
src = src.replace(/declare -A \w+=\(\n(?:\s*\["[a-z]+channel"\]="[^"]*"\n)+\s*\)/g, (m) => {
  n++;
  const head = m.split('\n')[0];
  return `${head}\n${n === 1 ? ccMap : fnMap}\n  )`;
});
fs.writeFileSync(p, src);
console.log(`  install-test-tools.sh — ${n} نگاشت بازنویسی شد`);
NODEEOF
fi

edit public/index.html \
  's#Every macro cell is an organization on a Hyperledger Fabric network. Antenna assignments,#هر سازمان یک دامنه اعتماد روی شبکه Hyperledger Fabric است. ارجاع بیمار،#' \
  's#attach every device to its nearest antenna, and commit the result on chain.#هر بیمار را به سریع‌ترین مرکز واجد شرایط ارجاع می‌دهد و نتیجه را روی زنجیره ثبت می‌کند.#'


# ── ۱۰. دور سوم: آرایه ساده کانال‌ها و متن صفحه سناریو ──
# install-test-tools.sh دو **آرایه ساده** CHANNELS هم دارد (نه فقط
# نگاشت associative) که دور دوم نگرفت: یکی فهرست کامل کانال‌ها و
# یکی زیرمجموعه بار-آزمایی. با کانال‌های 6G در آن، هر اجرا بیست
# خطای «کانال یافت نشد» می‌داد.
log "دور سوم: آرایه کانال‌ها و متن سناریو"

if [ "$DRY_RUN" != "1" ] && [ -f "$ROOT_DIR/scripts/install-test-tools.sh" ]; then
  node - "$ROOT_DIR" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const { CHANNEL_CHAINCODE_MAP } =
  require(path.join(root, 'server', 'contract-fn-map.js'));
const all = Object.keys(CHANNEL_CHAINCODE_MAP);
// زیرمجموعه بار-آزمایی: عمداً دو selector و دو ledger، تا آزمایش
// شاهد «هزینه پیچیدگی chaincode» از همان دود-تست هم در دسترس باشد.
const subset = ['admissionchannel', 'referralchannel', 'auditchannel', 'clinicalchannel'];

const p = path.join(root, 'scripts', 'install-test-tools.sh');
let src = fs.readFileSync(p, 'utf8');
let n = 0;

src = src.replace(/CHANNELS=\(\n(?:\s*"[a-z]+channel"[^\n]*\n)+\s*\)/g, () => {
  n++;
  const lines = [];
  for (let i = 0; i < all.length; i += 4) {
    lines.push('    ' + all.slice(i, i + 4).map((c) => `"${c}"`).join(' '));
  }
  return 'CHANNELS=(\n' + lines.join('\n') + '\n)';
});

src = src.replace(/CHANNELS=\("[a-z]+channel"(?:\s+"[a-z]+channel")*\)/g, () => {
  n++;
  return 'CHANNELS=(' + subset.map((c) => `"${c}"`).join(' ') + ')';
});

src = src.replace(/\$\{1:-iotchannel\}/g, () => { n++; return '${1:-admissionchannel}'; });
src = src.replace(/\\\$\{1:-iotchannel\}/g, () => { n++; return '\\${1:-admissionchannel}'; });

fs.writeFileSync(p, src);
console.log(`  install-test-tools.sh — ${n} آرایه/پیش‌فرض کانال به‌روز شد`);
NODEEOF
fi

edit public/scenario.html \
  "s#are scattered across the same area and attach to whichever antenna is closest — that antenna's#در همان ناحیه پراکنده‌اند و به سریع‌ترین مرکز واجد شرایط ارجاع می‌شوند — سازمان آن مرکز#" \
  's#antenna record that has to exist first.#چیدمان مراکز که باید از قبل بذرکاری شده باشد.#'


# ── ۱۱. دور چهارم: ارجاعات کد که crash می‌دهند ─────────
# 🔴 bench-routes.js میدان catalogue.SPATIAL_CONTRACTS.size را
# می‌خواند. آن میدان در کاتالوگ سلامت وجود ندارد → TypeError روی
# undefined.size → کل مسیر /api/bench/catalog می‌افتد. این نوع
# ارجاع با گشت واژگانی پیدا نمی‌شود چون واژه دامنه‌ای ندارد؛ فقط
# با بارگذاری واقعی ماژول‌ها دیده می‌شود (بررسی پایین).
log "دور چهارم: ارجاعات کد"

edit server/bench-routes.js \
  's#spatialContracts: catalogue.SPATIAL_CONTRACTS.size,#selectorContracts: catalogue.targetsByKind("selector").length,\n        ledgerContracts: catalogue.targetsByKind("ledger").length,#'

edit server/bench-runner.js \
  's#good for comparing contracts, but it is not what a live 6G network looks#برای مقایسه قراردادها خوب است، ولی شبیه بار واقعی یک شبکه سلامت نیست#'

edit server/patch-index.sh \
  "s#سناریوی شبیه‌سازی 6G (توپولوژی تصادفی + تخصیص نزدیک‌ترین آنتن)#سناریوی شبیه‌سازی سلامت (چیدمان مراکز + ارجاع بر پایه زمان سفر)#"

edit scripts/secure-dashboard.sh \
  's#6G Network Dashboard#Health Network Dashboard#'

# check-go.js فهرست توابع شناخته‌شده هسته را دارد. با نام‌های 6G
# در آن، هر بررسی «تابع تعریف‌نشده» روی قراردادهای سلامت مثبت
# کاذب می‌دهد.
edit scripts/check-go.js \
  "s#'SeedNetwork', 'SetPropagation', 'SetCapacity', 'saveAntenna', 'loadConfig',#'SeedFacilityLayout', 'SetConfig', 'getConfig', 'loadFacilities', 'commit',#" \
  "s#'listAntennas', 'evaluate', 'admit', 'ServingCell', 'NetworkStatus',#'evaluate', 'txTime', 'submitter', 'readAccount', 'writeAccount', 'NetworkStatus',#" \
  "s#entity-serving contracts have — the antenna-subject one must omit it.#قراردادهای selector دارند؛ ledger و guarded آن را ندارند.#" \
  "s#new Set(\['Antenna', 'Account', 'NetworkConfig', 'CellReport',#new Set(['Facility', 'Account', 'NetConfig', 'Record', 'Selection', 'News2Result', 'ClaimResult',#"


# ── ۱۲. دور پنجم: bootstrap-secure.sh ───────────────────
# 🔴 این‌ها را log واقعی سرور نشان داد، نه گشت من. سه اشکال که
# راه‌اندازی را در گام ۴/۷ متوقف می‌کرد:
#
#  ۱. دور دوم فقط `generateChaincodes_spatial.sh` را جایگزین کرد،
#     ولی bootstrap در عمل از glob `generateChaincodes_part*.sh`
#     استفاده می‌کند. آن فایل‌ها را port-from-6g.sh حذف کرده، پس
#     حلقه روی الگوی بی‌تطابق می‌چرخید و die می‌کرد.
#  ۲. شمارش `[ "$COUNT" -eq 86 ]` — عدد 6G. حالا ۱۱۰ قرارداد است.
#  ۳. `CHANNELS="${CHANNELS:-datachannel}"` — datachannel کانال 6G
#     است و در نگاشت سلامت وجود ندارد. حتی اگر گام ۴ می‌گذشت،
#     گام ۷ کانالی می‌ساخت که هیچ قراردادی روی آن نیست.
#
# درس: گشت واژگانی روی **نام فایل‌های شناخته‌شده** کافی نیست وقتی
# اسکریپت از glob استفاده می‌کند. تنها اجرای واقعی این را نشان داد.
log "دور پنجم: bootstrap-secure.sh"

if [ "$DRY_RUN" != "1" ] && [ -f "$ROOT_DIR/scripts/bootstrap-secure.sh" ]; then
  mkdir -p "$BK/scripts"; cp "$ROOT_DIR/scripts/bootstrap-secure.sh" "$BK/scripts/"
  node - "$ROOT_DIR" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const { CHANNEL_CHAINCODE_MAP, CONTRACT_FN } =
  require(path.join(root, 'server', 'contract-fn-map.js'));
const total = Object.keys(CONTRACT_FN).length;

const p = path.join(root, 'scripts', 'bootstrap-secure.sh');
let s = fs.readFileSync(p, 'utf8');
const before = s;

// ۱) glob تولید قراردادها → اسکریپت واحد سلامت
s = s.replace(
  /echo "    \\\$ for f in generateChaincodes_part\*\.sh; do bash \\"\\\$f\\"; done"/,
  'echo "    \\$ bash generateChaincodes_hospital.sh"');
s = s.replace(
  /for f in generateChaincodes_part\*\.sh; do\n\s*bash "\$f"[^\n]*\n\s*done/,
  'bash generateChaincodes_hospital.sh \\\n'
  + '        || die "generateChaincodes_hospital.sh شکست خورد — جداگانه اجرا کنید تا خطای کامپایل دیده شود"');

// ۲) شمارش قراردادها
s = s.replace(/\[ "\$COUNT" -eq 86 \] \|\| die "\$COUNT قرارداد تولید شد، انتظار ۸۶"/,
  `[ "$COUNT" -eq ${total} ] || die "$COUNT قرارداد تولید شد، انتظار ${total}"`);
s = s.replace(/ok "۸۶ قرارداد — و اسکریپت مکانی خودش کامپایل را بررسی کرد"/,
  `ok "${total} قرارداد — اسکریپت خودش کامپایل را بررسی کرد"`);

// ۳) کانال پیش‌فرض. admissionchannel انتخاب شده چون هر هفت
// قراردادش selector است — یعنی کوتاه‌ترین مسیر تا اولین عدد
// معنادار. auditchannel به عنوان شاهد کنارش می‌آید.
const def = 'admissionchannel';
s = s.replace(/CHANNELS="\$\{CHANNELS:-datachannel\}"/, `CHANNELS="\${CHANNELS:-${def}}"`);
s = s.replace(/# ۳ نود Raft، TLS کامل، datachannel/, `# ۳ نود Raft، TLS کامل، ${def}`);
s = s.replace(/CHANNELS="datachannel auditchannel"/, `CHANNELS="${def} auditchannel"`);
s = s.replace(/# هر ۲۰ کانال \(طولانی\)/,
  `# هر ${Object.keys(CHANNEL_CHAINCODE_MAP).length} کانال (طولانی)`);

// ۴) عنوان
s = s.replace(/راه‌اندازی شبکه 6G از صفر/g, 'راه‌اندازی شبکه ملی سلامت از صفر');

if (s === before) {
  console.error('  هشدار: هیچ الگویی در bootstrap-secure.sh تطبیق نیافت');
} else {
  fs.writeFileSync(p, s);
  console.log('  bootstrap-secure.sh به‌روز شد');
}

// اعتبارسنجی: هر کانالی که در پیش‌فرض یا مثال‌ها آمده باید واقعاً
// در نگاشت باشد. اگر نبود، گام ۷ کانالی می‌سازد که قرارداد ندارد.
const body = fs.readFileSync(p, 'utf8');
const named = [...new Set([...body.matchAll(/\b(\w+channel)\b/g)].map((m) => m[1]))];
const bad = named.filter((c) => !(c in CHANNEL_CHAINCODE_MAP));
if (bad.length) {
  console.error('  ✗ کانال‌های ناموجود در bootstrap:', bad.join(', '));
  process.exit(1);
}
console.log(`  ✓ هر ${named.length} کانال نام‌برده در نگاشت وجود دارد`);
NODEEOF
fi


# ── ۱۳. دور ششم: ارجاع به فایل‌های حذف‌شده ─────────────
# با یک گشت ایستا روی همه `./x.sh`، `bash x.sh`، `node x.js` در
# اسکریپت‌ها پیدا شدند. هیچ‌کدام واژه دامنه‌ای نداشتند، پس گشت‌های
# قبلی نگرفتند — و هر دو فقط هنگام اجرا خطا می‌دادند.
#
#  · update-fn-map.js — در 6G نگاشت توابع را از کد Go مهندسی
#    معکوس می‌کرد. اینجا مولد خودش آن را می‌سازد، پس فایل حذف شده.
#  · seed-network.sh در راهنمای پایانی setup-raft.sh
log "دور ششم: ارجاع به فایل‌های حذف‌شده"

edit scripts/bootstrap-secure.sh \
  's#node update-fn-map.js >/dev/null 2>&1 \&\& ok "نگاشت توابع"#node gen-hospital-contracts.js >/dev/null 2>\&1 \&\& ok "نگاشت توابع و مانیفست امضاها"#'

edit scripts/setup-raft.sh \
  's#\./seed-network\.sh datachannel#./seed-hospital.sh admissionchannel#'


# ── ۱۴. دور هفتم: پیام هشدار حافظه ─────────────────────
# log سرور نشان داد: «حافظه آزاد 1712MB ... اگر OOM دیدید،
# NODES=3 را امتحان کنید» — در حالی که NODES از قبل ۳ بود. توصیه
# بی‌معنا بود و کاربر را سردرگم می‌کرد.
#
# و برآورد هم دقیق نیست: فرمول 1200+200×نود برای peer ها است، ولی
# در عمل مصرف اوج هنگام **کامپایل Go قراردادها** رخ می‌دهد
# (dev-container). با ۱۱۰ قرارداد این بیشتر از 6G است.
log "دور هفتم: پیام حافظه"

if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$BK/scripts"
  cp "$ROOT_DIR/scripts/bootstrap-secure.sh" "$BK/scripts/bootstrap-secure.mem.sh"
  node - "$ROOT_DIR" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const p = path.join(process.argv[2], 'scripts', 'bootstrap-secure.sh');
let s = fs.readFileSync(p, 'utf8');
const before = s;
s = s.replace(
  /    warn "اگر OOM دیدید، NODES=3 را امتحان کنید"/,
  `    if [ "$NODES" -gt 3 ]; then
        warn "با NODES=3 دوباره امتحان کنید (هر نود اضافه ~200MB)"
    else
        warn "کمترین پیکربندی همین است. پیش از ادامه:"
        warn "  systemctl stop dashboard 2>/dev/null"
        warn "  docker system prune -f"
        warn "مصرف اوج هنگام کامپایل Go قراردادهاست، نه اجرای peer ها —"
        warn "پس اگر گام ۴/۷ گذشت، بقیه معمولاً می‌گذرد."
    fi`);
if (s === before) console.error('  هشدار: پیام حافظه تطبیق نیافت');
else { fs.writeFileSync(p, s); console.log('  پیام حافظه اصلاح شد'); }
NODEEOF
  bash -n "$ROOT_DIR/scripts/bootstrap-secure.sh" || { echo "  ✗ نحو bootstrap شکست"; exit 1; }
fi

# ── تأیید ───────────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN — هیچ تغییری اعمال نشد"
  exit 0
fi

log "تأیید"
FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then echo "  ✓ $1"; else echo "  ✗ $1"; FAIL=$((FAIL+1)); fi
}

check "scenario-core با هسته Go همگام است" \
      "cd '$ROOT_DIR/server' && node -e '
        const d=require(\"./scenario-core\").assertKernelInSync();
        if(d.length){console.error(d);process.exit(1);}'"
check "نقشه حوزه نحو درست دارد" \
      "node --check '$ROOT_DIR/public/catchment-map.js'"
check "app.js نحو درست دارد" \
      "node --check '$ROOT_DIR/public/app.js'"
check "test-app.js نحو درست دارد" \
      "node --check '$ROOT_DIR/public/test-app.js'"
check "scenario-app.js نحو درست دارد" \
      "node --check '$ROOT_DIR/public/scenario-app.js'"
check "coverage-map.js حذف شده" \
      "[ ! -f '$ROOT_DIR/public/coverage-map.js' ]"
check "کاتالوگ بنچمارک بارگذاری می‌شود" \
      "cd '$ROOT_DIR/server' && node -e 'require(\"./bench-catalog\").catalog()'"
check "home.js نحو درست دارد" \
      "node --check '$ROOT_DIR/public/home.js'"
check "دود-تست کانال‌های واقعی را می‌زند" \
      "! grep -qE 'networkchannel|iotchannel|securitychannel' '$ROOT_DIR/scripts/install-test-tools.sh'"
# سه فایل عمداً واژه آنتن را دارند و مستثنا هستند:
#   catchment-map.js و scenario-core.js — جدول تناظر 6G ↔ سلامت
#     در کامنت‌ها، که برای فهم طراحی لازم است
#   bench-catalog.js — ANTENNA_COUNT به عنوان نام سازگاری، چون
#     gen-caliper-assets.js آن را می‌خواند و بازنویسی آن فایل
#     ارزش ریسکش را ندارد
# 🔴 مهم‌ترین بررسی: ماژول‌های سرور را واقعاً بارگذاری کن. گشت
# واژگانی ارجاعی مثل catalogue.SPATIAL_CONTRACTS را نمی‌گیرد چون
# هیچ واژه دامنه‌ای ندارد — فقط اجرا آن را نشان می‌دهد.
check "ماژول‌های سرور بارگذاری می‌شوند" \
      "cd '$ROOT_DIR/server' && node -e '
        require(\"./bench-catalog\"); require(\"./contract-fn-map\");
        require(\"./scenario-core\");
        const s=require(\"fs\").readFileSync(\"./bench-routes.js\",\"utf8\");
        const bad=[...s.matchAll(/catalogue\\.(\\w+)/g)].map(m=>m[1])
          .filter(k=>!(k in require(\"./bench-catalog\")));
        if(bad.length){console.error(\"میدان ناموجود در کاتالوگ:\",bad);process.exit(1);}'"
# bootstrap باید بدون هیچ ارجاع به فایل یا کانال ناموجود باشد.
# این بررسی مستقیماً از log سرور آمد.
check "bootstrap به فایل ناموجود ارجاع نمی‌دهد" \
      "! grep -qE 'generateChaincodes_(part|spatial)|upgrade-spatial|seed-network\.sh' \
         '$ROOT_DIR/scripts/bootstrap-secure.sh'"
check "همه اسکریپت‌ها نحو درست دارند" \
      "cd '$ROOT_DIR' && for f in scripts/*.sh server/*.sh install.sh; do bash -n \"\$f\" || exit 1; done"
check "کانال‌های bootstrap در نگاشت وجود دارند" \
      "cd '$ROOT_DIR/server' && node -e '
        const fs=require(\"fs\");
        const {CHANNEL_CHAINCODE_MAP}=require(\"./contract-fn-map\");
        const b=fs.readFileSync(\"../scripts/bootstrap-secure.sh\",\"utf8\");
        const bad=[...new Set([...b.matchAll(/\\b(\\w+channel)\\b/g)].map(m=>m[1]))]
          .filter(c=>!(c in CHANNEL_CHAINCODE_MAP));
        if(bad.length){console.error(bad);process.exit(1);}'"
# 🔴 این بررسی کل کلاس خطا را می‌گیرد، نه یک نمونه را. دو باگ
# آخر (generateChaincodes_part*.sh و update-fn-map.js) هر دو
# «ارجاع به فایلی که port حذفش کرده» بودند و هیچ واژه دامنه‌ای
# نداشتند، پس با grep پیدا نمی‌شدند. حالا هر ارجاع به اسکریپتی
# که وجود ندارد، همین‌جا می‌افتد.
# خود این اسکریپت و port-from-6g.sh مستثنا هستند: کارشان دقیقاً
# نام‌بردن از فایل‌هایی است که حذف شده‌اند (در الگوهای sed و در
# کامنت‌ها)، پس همیشه مثبت کاذب می‌دهند.
check "هیچ اسکریپتی به فایل غایب ارجاع نمی‌دهد" \
      "[ -z \"\$(cd '$ROOT_DIR' && for f in scripts/*.sh server/*.sh install.sh; do
          case \"\$f\" in *patch-domain.sh|*port-from-6g.sh) continue;; esac
          grep -oE '\\./[A-Za-z0-9_.-]+\\.(sh|js)|\\b(bash|node|source) +[A-Za-z0-9_./-]+\\.(sh|js)' \"\$f\" 2>/dev/null \
          | sed -E 's/^(bash|node|source) +//; s#^\\./##' | sort -u \
          | while read r; do b=\"\$(basename \"\$r\")\";
              [ -f \"scripts/\$b\" ] || [ -f \"server/\$b\" ] || [ -f \"\$b\" ] || echo \"\$f→\$b\"; done;
        done)\" ]"
check "هیچ ارجاع آنتن در کد فعال نمانده" \
      "[ -z \"\$(grep -rilE 'antenna|آنتن' --include='*.js' --include='*.html' \
         '$ROOT_DIR/public' '$ROOT_DIR/server' \
         | grep -vE 'catchment-map|scenario-core|bench-catalog')\" ]"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "[$(date +'%H:%M:%S')] خطا: $FAIL بررسی شکست خورد. پشتیبان در $BK" >&2
  exit 1
fi
log "پاک‌سازی دامنه کامل شد. پشتیبان: $BK"
