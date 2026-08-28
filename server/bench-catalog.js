'use strict';

/* ═══════════════════════════════════════════════════════════════════════
   bench-catalog.js — منبع واحد حقیقت برای اهداف بنچمارک (نسخه سلامت)

   جایگزین مستقیم server/bench-catalog.js پروژه 6G. همان امضای export
   را دارد، پس bench-runner.js، gen-caliper-assets.js و bench-routes.js
   بدون تغییر کار می‌کنند.

   یک «هدف» یک جفت (کانال، قرارداد) است. هر اجرای بنچمارک — از یک
   قرارداد تا جاروی کامل ۲۰ کانال — فقط یک فهرست هدف است، پس همان
   مسیر کد به همه حالت‌های رابط کاربری سرویس می‌دهد.

   داده امضاها از contract-fn-map.js می‌آید که خودش توسط
   gen-hospital-contracts.js تولید شده — همان مولدی که chaincode را
   می‌نویسد. در 6G این نگاشت با مهندسی معکوس ساخته می‌شد و هر بار که
   امضایی عوض می‌شد باید دوباره تحلیل می‌شد.
   ═══════════════════════════════════════════════════════════════════════ */

const { CONTRACT_FN, CHANNEL_CHAINCODE_MAP, READ_ONLY_CONTRACTS } =
  require('./contract-fn-map');

/* ── پارامترهای سناریو ─────────────────────────────────────
   باید با آرگومان‌های seed-hospital.sh یکی باشند، وگرنه بنچمارک
   بیمارانی می‌سازد که خارج از شبکه بذرکاری‌شده‌اند و همه رد می‌شوند.
   در 6G همین ناهمخوانی باعث شد مختصات ۱..۱۰۰ روی شبکه ۱۰ کیلومتری
   ارزیابی شود. */
const BENCH_SEED = 'seed-1404';
const GRID_SIZE_M = 30000;
const FACILITY_COUNT = 12;

const READ_FN = 'QueryRecord';
const READ_ALL_FN = 'QueryAllRecords';
const SEED_FN = 'SeedFacilityLayout';

/* ── تولید مقدار هر پارامتر ───────────────────────────────

   اصل: هر تراکنش باید کلید یکتای خودش را بنویسد، وگرنه تعارض MVCC
   می‌سازد و نتیجه بنچمارک بی‌معنا می‌شود.

   ⚠️ توزیع علائم حیاتی اینجا **عمداً واقع‌گرایانه** است، نه همیشه
   طبیعی. اگر همه بیماران را سالم بسازیم، هر تراکنش سطح ۵ می‌گیرد،
   پنجره ۴ ساعته دارد و هیچ‌وقت رد نمی‌شود — و آن‌وقت بنچمارک هرگز
   مسیر رد را اجرا نمی‌کند. نرخ پذیرش باید همان چیزی باشد که
   شبیه‌سازی نشان داد (حدود ۹۲٪). */
function paramValue(name, i, keyPrefix) {
  const h = (s) => {
    let x = 2166136261;
    for (const ch of String(s)) { x ^= ch.charCodeAt(0); x = Math.imul(x, 16777619); }
    x ^= x >>> 16; x = Math.imul(x, 0x85ebca6b);
    x ^= x >>> 13; x = Math.imul(x, 0xc2b2ae35);
    x ^= x >>> 16;
    return Math.abs(x);
  };
  const r = (lo, hi, salt) => lo + (h(`${keyPrefix}-${i}-${salt}`) % (hi - lo + 1));

  switch (name) {
    /* کلیدها — هر تراکنش یکتا */
    case 'id':              return `${keyPrefix}-${i}`;
    case 'unitID':          return `${keyPrefix}-unit-${i}`;
    case 'claimID':         return `${keyPrefix}-claim-${i}`;
    case 'facilityID':      return `facility-${1 + (i % FACILITY_COUNT)}`;
    case 'subject':         return `${keyPrefix}-subj-${i}`;
    case 'detail':          return `bench-${i}`;
    case 'drugCode':        return `drug-${i % 200}`;
    case 'owner':
    case 'from':
    case 'lender':          return `${keyPrefix}-a-${i}`;
    case 'to':
    case 'borrower':        return `${keyPrefix}-b-${i}`;

    /* تعهد شناسه بیمار — شناسه خام هرگز به قرارداد نمی‌رود */
    case 'patientCommit':
    case 'recipientCommit': return h(`${keyPrefix}-p-${i}`).toString(16).padStart(16, '0');

    /* مکان — روی کل شبکه بذرکاری‌شده، نه یک گوشه آن */
    case 'x':               return String(r(0, GRID_SIZE_M - 1, 'x'));
    case 'y':               return String(r(0, GRID_SIZE_M - 1, 'y'));

    /* علائم حیاتی — ۷۸٪ طبیعی، ۲۲٪ منحرف */
    case 'rr':              return String(r(0, 99, 'rr') < 78 ? r(12, 20, 'rr2') : r(6, 34, 'rr3'));
    case 'spo2':            return String(r(0, 99, 'sp') < 78 ? r(96, 100, 'sp2') : r(84, 95, 'sp3'));
    case 'onOxygen':        return r(0, 99, 'ox') < 88 ? '0' : '1';
    case 'sbp':             return String(r(0, 99, 'bp') < 78 ? r(111, 160, 'bp2') : r(70, 215, 'bp3'));
    case 'hr':              return String(r(0, 99, 'hr') < 78 ? r(55, 90, 'hr2') : r(38, 145, 'hr3'));
    case 'avpu':            return r(0, 99, 'av') < 97 ? '0' : '1';
    case 'tempMilliC':      return String(r(0, 99, 'tp') < 78 ? r(36200, 37800, 'tp2') : r(35200, 39600, 'tp3'));
    case 'flags':           return String(r(0, 99, 'fl') < 88 ? 0 : 1 << r(0, 7, 'fl2'));
    // ≥۱۶ سال: زیر آن Scale2Required فعال می‌شود و قرارداد **عمداً**
    // تصمیم نمی‌گیرد. اگر بنچمارک نوزاد بسازد، نرخ رد را با شکست
    // اشتباه می‌گیرید.
    case 'ageYears':        return String(r(16, 92, 'ag'));

    /* خون */
    case 'donorType':       return String(r(0, 7, 'dt'));
    case 'recipientType':   return String(r(0, 7, 'rt'));
    case 'product':         return String(r(0, 2, 'pr'));
    case 'expirySec':       return String(Math.floor(Date.now() / 1000) + 86400 * 30);

    /* دارو */
    case 'drugClassMask':   return String(1 << r(0, 7, 'dc'));
    case 'allergyMask':     return String(r(0, 99, 'am') < 92 ? 0 : 1 << r(0, 7, 'am2'));
    case 'weightGrams':     return String(r(45000, 110000, 'wg'));
    case 'minPerKgMicro':   return '10';
    case 'maxPerKgMicro':   return '20';
    case 'orderedMicro':    return String(r(700, 1400, 'od'));
    case 'renalMilli':      return String(r(0, 99, 'rn') < 85 ? 1000 : 500);

    /* مالی */
    case 'tariffMicro':     return String(r(200000, 5000000, 'tf'));
    case 'coverageMilli':   return String(r(50000, 90000, 'cv'));
    case 'deductibleMicro': return '100000';
    case 'remainingCapMicro': return '-1';
    case 'amount':          return '1000';
    case 'priceMicro':      return '500';
    case 'beds':            return String(r(1, 3, 'bd'));

    /* عمومی guarded */
    case 'condition':       return String(r(0, 100, 'cd'));
    case 'threshold':       return '20';

    default:                return `${keyPrefix}-${name}-${i}`;
  }
}

/** آرگومان‌های یک فراخوانی نوشتن. */
function buildArgs(contract, i, keyPrefix) {
  const def = CONTRACT_FN[contract];
  if (!def) throw new Error(`قرارداد ناشناخته: ${contract}`);
  return def.params.map((p) => paramValue(p, i, keyPrefix || contract.toLowerCase()));
}

/** کلید دفتری که فراخوانی i می‌نویسد — برای بررسی پس از اجرا. */
function buildKey(contract, i, keyPrefix) {
  const def = CONTRACT_FN[contract];
  const first = def.params[0];
  return paramValue(first, i, keyPrefix || contract.toLowerCase());
}

/** آرگومان‌های بذرکاری. باید با seed-hospital.sh یکی باشد. */
function seedArgs() {
  return [BENCH_SEED, String(GRID_SIZE_M), String(FACILITY_COUNT), '0'];
}

/* ── عملیات بازار ─────────────────────────────────────────

   در پروژه 6G بازار مجموعه‌ای از **توابع اضافه** روی قراردادهای
   موجود بود (Mint، Transfer، BuyQos، ShareBandwidth، RelayFor) و
   MARKET_FN آنها را توصیف می‌کرد. اینجا بازار قراردادهای مستقل
   خودش را دارد (kind: market)، پس MARKET_FN از همان‌ها مشتق
   می‌شود. این نام حفظ شده چون bench-routes.js آن را می‌خواند —
   بدون آن، مسیر /api/bench/catalog با TypeError می‌افتد.       */
const MARKET_FN = {};
for (const [name, def] of Object.entries(CONTRACT_FN)) {
  if (def.kind !== 'market') continue;
  MARKET_FN[name] = {
    fn: def.fn,
    params: def.params,
    writePattern: 'unique',
    tapeSafe: def.tapeSafe,
    note: name === 'ShareBedCapacity'
      ? 'اجاره ظرفیت تخت — نیازمند تخت آزاد واقعی و موجودی حساب'
      : name === 'TransferToken'
        ? 'انتقال بین دو حساب — خواندن-تغییر-نوشتن'
        : 'عملیات توکن',
    requires: def.tapeSafe ? undefined
      : 'فقط Caliper — Tape آرگومان ثابت می‌فرستد و حالت مشترک را تمام می‌کند',
  };
}

function marketTargets() {
  return allTargets().filter((t) => t.kind === 'market');
}

function buildMarketArgs(contract, i, keyPrefix) {
  return buildArgs(contract, i, keyPrefix);
}


/** channelEntries — شکلی که صفحهٔ بنچمارک برای ساخت dropdown
 *  لازم دارد: آرایه‌ای از { channel, contracts: [...] }.
 *  test-app.js روی این `forEach` و `find` می‌زند، پس عدد بودنش
 *  صفحه را با «cat.channels.forEach is not a function» می‌خواباند. */
function channelEntries() {
  return Object.keys(CHANNEL_CHAINCODE_MAP).map((channel) => ({
    channel,
    contracts: allTargets()
      .filter((t) => t.channel === channel)
      .map((t) => ({
        contract: t.contract,
        fn: t.fn,
        kind: t.kind,
        params: t.params,
        writable: t.writable,
        needsSeed: t.needsSeed,
        tapeSafe: t.tapeSafe,
        caliperId: t.caliperId,
        id: t.id,
      })),
  })).filter((c) => c.contracts.length);
}

/* ── اهداف ───────────────────────────────────────────────── */

function allTargets() {
  const out = [];
  for (const [channel, list] of Object.entries(CHANNEL_CHAINCODE_MAP)) {
    for (const contract of list) {
      const def = CONTRACT_FN[contract];
      if (!def || def.readOnly) continue;
      out.push({
        channel,
        contract,
        fn: def.fn,
        kind: def.kind,
        needsSeed: def.needsSeed,
        tapeSafe: def.tapeSafe,
        id: `${channel}/${contract}`,
        // `writable` قرارداد نسخه 6G است. gen-caliper-assets.js
        // با `if (!t.writable) continue` فیلتر می‌کند؛ بدون این
        // میدان هیچ workload نام‌داری ساخته نمی‌شود و بنچمارک
        // هدفمند از رابط کاربری کار نمی‌کند.
        // اینجا هر هدف نوشتنی است — readOnly ها بالاتر فیلتر شده‌اند.
        writable: true,
        params: def.params,
        caliperId: caliperId({ channel, contract }),
      });
    }
  }
  return out;
}

/** اهداف یک نوع رفتاری — برای آزمایش شاهد selector در برابر ledger. */
function targetsByKind(kind) {
  return allTargets().filter((t) => t.kind === kind);
}

function resolveTargets(spec) {
  const all = allTargets();
  if (!spec || spec === 'all') return all;
  if (Array.isArray(spec)) {
    const want = new Set(spec);
    return all.filter((t) => want.has(t.id) || want.has(t.channel) || want.has(t.contract));
  }
  if (typeof spec === 'string') {
    if (spec.startsWith('kind:')) return targetsByKind(spec.slice(5));
    return all.filter((t) => t.channel === spec || t.contract === spec || t.id === spec);
  }
  return all;
}

function tapeTargets() { return allTargets().filter((t) => t.tapeSafe); }

function caliperId(t) { return `${t.channel}_${t.contract}`; }

function describeTarget(t) {
  const def = CONTRACT_FN[t.contract];
  return `${t.id} → ${def.fn}(${def.params.join(', ')}) [${def.kind}]`;
}

/** آماری که در رابط کاربری نشان داده می‌شود. */
function catalog() {
  const targets = allTargets();
  const byKind = {};
  for (const t of targets) byKind[t.kind] = (byKind[t.kind] || 0) + 1;
  return {
    seed: BENCH_SEED,
    gridSizeM: GRID_SIZE_M,
    facilityCount: FACILITY_COUNT,
    // آرایه، نه عدد — رابط کاربری روی این forEach می‌زند.
    // شمارنده‌ها در counts پایین‌اند.
    channels: channelEntries(),
    targets,
    byKind,
    // `counts` قرارداد نسخه 6G است: add-test-endpoint.sh و هر
    // مصرف‌کننده‌ای که از آنجا آمده باشد اینجا را می‌خواند. همان
    // اعداد ریشه، فقط با شکل قدیمی — تا هیچ‌کدام نشکند.
    counts: {
      channels: Object.keys(CHANNEL_CHAINCODE_MAP).length,
      contracts: Object.keys(CONTRACT_FN).length,
      targets: targets.length,
      tapeSafe: tapeTargets().length,
      // هر هدف نوشتنی است — readOnly ها در allTargets فیلتر شده‌اند.
      writable: targets.length,
      // نام 6G برای «نیازمند بذرکاری». gen-caliper-assets.js آن را
      // در خلاصه چاپ می‌کند؛ بدونش «undefined» می‌نویسد.
      antennaDep: targets.filter((t) => t.needsSeed).length,
      needsSeed: targets.filter((t) => t.needsSeed).length,
      selector: targetsByKind('selector').length,
      ledger: targetsByKind('ledger').length,
      readOnly: READ_ONLY_CONTRACTS.length,
    },
  };
}

/** ناهمخوانی با fabric.js را گزارش می‌کند (اگر SDK نصب باشد). */
function assertCatalogInSync() {
  let other;
  try { ({ CHANNEL_CHAINCODE_MAP: other } = require('./fabric')); }
  catch (_) { return []; }
  const diffs = [];
  const keys = new Set([...Object.keys(CHANNEL_CHAINCODE_MAP), ...Object.keys(other)]);
  for (const k of keys) {
    const a = (CHANNEL_CHAINCODE_MAP[k] || []).slice().sort().join(',');
    const b = (other[k] || []).slice().sort().join(',');
    if (a !== b) diffs.push(k);
  }
  return diffs;
}

module.exports = {
  CONTRACT_FN,
  CHANNEL_CHAINCODE_MAP,
  READ_ONLY_CONTRACTS,
  BENCH_SEED,
  GRID_SIZE_M,
  FACILITY_COUNT,
  READ_FN,
  READ_ALL_FN,
  SEED_FN,
  buildArgs,
  buildKey,
  seedArgs,
  describeTarget,
  allTargets,
  targetsByKind,
  tapeTargets,
  resolveTargets,
  catalog,
  caliperId,
  channelEntries,
  assertCatalogInSync,
  MARKET_FN,
  marketTargets,
  buildMarketArgs,
  // نام‌های 6G که bench-routes.js/gen-caliper-assets.js می‌خوانند.
  // در دامنه سلامت مفهوم «مکانی» به «selector» تغییر نام داده،
  // ولی export حفظ می‌شود تا آن دو فایل بدون تغییر کار کنند.
  get SPATIAL_CONTRACTS() { return new Set(targetsByKind('selector').map((t) => t.contract)); },
  ANTENNA_COUNT: FACILITY_COUNT,
  writeFunctions: () => allTargets().map((t) => ({ contract: t.contract, fn: t.fn })),
};
