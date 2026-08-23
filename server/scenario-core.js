'use strict';

// ═══════════════════════════════════════════════════════════════
// scenario-core.js — منطق خالص سناریوی شبکه سلامت
//
// جایگزین نسخه 6G که آنتن ماکروسل و دستگاه IoT می‌ساخت. ساختار
// یکسان نگه داشته شده تا scenario-routes.js کار کند:
//
//   6G                        سلامت
//   ────────────────────────  ──────────────────────────────
//   آنتن ماکروسل             مرکز درمانی
//   دستگاه IoT / کاربر        بیمار
//   اتصال به نزدیک‌ترین آنتن   ارجاع به سریع‌ترین مرکز واجد شرایط
//   ورونوی بر پایه فاصله      ورونوی بر پایه زمان سفر + توانمندی
//
// این ماژول هیچ وابستگی به فابریک ندارد و مستقلاً قابل تست است.
//
// ⚠️ هشداری که در نسخه 6G هم بود و همچنان برقرار است:
// قراردادها چیدمان **خودشان** را دارند که SeedFacilityLayout ساخته
// و از مولد دیگری می‌آید (FNV+Murmur در clinical.go، نه mulberry32
// اینجا). بذر یکسان مختصات یکسان **نمی‌دهد**. قرارداد منبع حقیقت
// است — چیدمانش را با QueryFacility بگیرید و به عنوان `facilities`
// پاس دهید تا نقشه آنچه را دفتر واقعاً حساب می‌کند نشان دهد.
// ═══════════════════════════════════════════════════════════════

const { CONTRACT_FN, CHANNEL_CHAINCODE_MAP } = require('./contract-fn-map');

/* ── RNG قطعی ────────────────────────────────────────── */
function makeRng(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/* ── ثابت‌های دامنه — آینه clinical.go ────────────────── */
const CAP = {
  Emergency: 1 << 0, ICU: 1 << 1, NICU: 1 << 2, Trauma: 1 << 3,
  CathLab: 1 << 4, Stroke: 1 << 5, Surgery: 1 << 6, Obstetric: 1 << 7,
  Dialysis: 1 << 8, Burn: 1 << 9, Pediatric: 1 << 10, Oncology: 1 << 11,
  Psych: 1 << 12, Imaging: 1 << 13, Lab: 1 << 14, BloodBank: 1 << 15,
};

const FLAG = {
  Airway: 1 << 0, Cardiac: 1 << 1, Stroke: 1 << 2, Trauma: 1 << 3,
  Hemorrage: 1 << 4, Sepsis: 1 << 5, Labor: 1 << 6, Burn: 1 << 7,
};

const CAP_LABEL = {
  Emergency: 'اورژانس', ICU: 'مراقبت ویژه', NICU: 'ویژه نوزادان',
  Trauma: 'ترومای سطح یک', CathLab: 'آنژیوگرافی', Stroke: 'واحد سکته',
  Surgery: 'اتاق عمل', Obstetric: 'زایمان', Dialysis: 'دیالیز',
  Burn: 'سوختگی', Pediatric: 'اطفال', Oncology: 'انکولوژی',
  Psych: 'روان', Imaging: 'تصویربرداری', Lab: 'آزمایشگاه',
  BloodBank: 'بانک خون',
};

// همان پروفایل‌هایی که SeedFacilities در clinical.go می‌سازد.
const FACILITY_PROFILES = [
  { label: 'مرکز جامع ترومای سطح یک',
    cap: CAP.Emergency | CAP.ICU | CAP.Trauma | CAP.Surgery | CAP.Imaging
       | CAP.Lab | CAP.BloodBank | CAP.CathLab | CAP.Stroke | CAP.NICU
       | CAP.Obstetric | CAP.Pediatric | CAP.Burn | CAP.Dialysis | CAP.Oncology },
  { label: 'بیمارستان عمومی با ICU و زایمان',
    cap: CAP.Emergency | CAP.ICU | CAP.Surgery | CAP.Imaging | CAP.Lab
       | CAP.BloodBank | CAP.Obstetric | CAP.Pediatric },
  { label: 'بیمارستان قلب و عروق',
    cap: CAP.Emergency | CAP.Surgery | CAP.Imaging | CAP.Lab | CAP.CathLab | CAP.ICU },
  { label: 'درمانگاه با دیالیز',
    cap: CAP.Emergency | CAP.Imaging | CAP.Lab | CAP.Dialysis },
  { label: 'درمانگاه اطفال',
    cap: CAP.Emergency | CAP.Lab | CAP.Pediatric | CAP.Imaging },
];

const GOLDEN_WINDOW = { 1: 900, 2: 1800, 3: 3600, 4: 7200, 5: 14400 };

const REJECT = {
  0: 'پذیرفته',
  1: 'هیچ مرکزی تعریف نشده',
  2: 'توانمندی لازم موجود نیست',
  3: 'خارج از پنجره طلایی',
  4: 'همه مراکز اشباع',
};

function capabilityNames(mask) {
  return Object.keys(CAP).filter((k) => mask & CAP[k]).map((k) => CAP_LABEL[k]);
}

/* ── NEWS2 — آینه دقیق clinical.go ───────────────────── */
function news2(v) {
  const { rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC } = v;
  const s = {
    resp:  rr <= 8 ? 3 : rr <= 11 ? 1 : rr <= 20 ? 0 : rr <= 24 ? 2 : 3,
    spo2:  spo2 <= 91 ? 3 : spo2 <= 93 ? 2 : spo2 <= 95 ? 1 : 0,
    air:   onOxygen ? 2 : 0,
    sbp:   sbp <= 90 ? 3 : sbp <= 100 ? 2 : sbp <= 110 ? 1 : sbp <= 219 ? 0 : 3,
    pulse: hr <= 40 ? 3 : hr <= 50 ? 1 : hr <= 90 ? 0 : hr <= 110 ? 1 : hr <= 130 ? 2 : 3,
    avpu:  avpu !== 0 ? 3 : 0,
    temp:  tempMilliC <= 35000 ? 3 : tempMilliC <= 36000 ? 1
         : tempMilliC <= 38000 ? 0 : tempMilliC <= 39000 ? 1 : 2,
  };
  const total = Object.values(s).reduce((a, b) => a + b, 0);
  const maxSingle = Math.max(...Object.values(s));
  const riskBand = total >= 7 ? 3 : total >= 5 ? 2 : maxSingle >= 3 ? 1 : 0;
  return { ...s, total, maxSingle, riskBand };
}

/* ── تریاژ — آینه TriageLevel ────────────────────────── */
function triage(n, flags, ageYears) {
  let need = CAP.Emergency;
  let level = 5;

  if (n.riskBand >= 3 || n.avpu >= 3) level = 1;
  else if (n.riskBand === 2 || n.maxSingle >= 3) level = 2;
  else if (n.total >= 3) level = 3;
  else if (n.total >= 1) level = 4;

  const esc = (l, caps) => { level = Math.min(level, l); need |= caps; };
  if (flags & FLAG.Airway)    esc(1, CAP.ICU);
  if (flags & FLAG.Cardiac)   esc(2, CAP.CathLab | CAP.ICU);
  if (flags & FLAG.Stroke)    esc(1, CAP.Stroke | CAP.Imaging);
  if (flags & FLAG.Trauma)    esc(1, CAP.Trauma | CAP.Surgery);
  if (flags & FLAG.Hemorrage) esc(2, CAP.Surgery | CAP.BloodBank);
  if (flags & FLAG.Sepsis)    esc(2, CAP.ICU | CAP.Lab);
  if (flags & FLAG.Labor)     esc(2, CAP.Obstetric);
  if (flags & FLAG.Burn)      esc(1, CAP.Burn | CAP.ICU);
  if (ageYears < 16) need |= CAP.Pediatric;
  if (ageYears < 1)  need |= CAP.NICU;

  return { level, need };
}

function travelTimeSec(straightM, speedKmh, congestionMilli, dispatchSec) {
  const roadM = Math.floor(straightM * 1300 / 1000);
  const mmPerSec = Math.floor(speedKmh * 1000 * 1000 / 3600);
  if (mmPerSec <= 0) return dispatchSec;
  const base = Math.floor(roadM * 1000 / mmPerSec);
  return dispatchSec + Math.floor(base * congestionMilli / 1000);
}

/* ── تولید توپولوژی ─────────────────────────────────── */
function generateTopology({
  seed, areaMeters = 30000, orgCount = 8,
  facilityCount = 12, patientCount = 40,
  facilities: fromLedger = null,
} = {}) {
  const realSeed = Number.isFinite(seed) ? seed : Math.floor(Math.random() * 2 ** 31);
  const rng = makeRng(realSeed);
  const rand = () => Math.round(rng() * areaMeters);

  let facilities = [];
  for (let i = 1; i <= facilityCount; i++) {
    const p = FACILITY_PROFILES[(i - 1) % FACILITY_PROFILES.length];
    facilities.push({
      id: `facility-${i}`,
      orgNum: ((i - 1) % orgCount) + 1,
      x: rand(), y: rand(),
      capability: p.cap, label: p.label,
      capabilityNames: capabilityNames(p.cap),
      totalBeds: 30 + Math.floor(rng() * 370),
      usedBeds: 0, queueLen: 0,
      speedKmh: 45,
      congestion: 1000 + Math.floor(rng() * 1200),
      fromLedger: false,
    });
  }

  if (Array.isArray(fromLedger) && fromLedger.length) {
    facilities = fromLedger.map((f, i) => {
      const cap = Number(f.capability) || CAP.Emergency;
      return {
        id: f.id || `facility-${i + 1}`,
        orgNum: (i % orgCount) + 1,
        x: Number(f.x), y: Number(f.y),
        capability: cap,
        label: FACILITY_PROFILES[i % FACILITY_PROFILES.length].label,
        capabilityNames: capabilityNames(cap),
        totalBeds: Number(f.totalBeds) || 0,
        usedBeds: Number(f.usedBeds) || 0,
        queueLen: Number(f.queueLen) || 0,
        speedKmh: Number(f.speedKmh) || 45,
        congestion: Number(f.congestion) || 1000,
        fromLedger: true,
      };
    });
  }

  // بیماران — توزیع علائم حیاتی مثل کاتالوگ بنچمارک: اکثریت
  // طبیعی، اقلیت منحرف. اگر همه سالم باشند هیچ ارجاعی رد نمی‌شود
  // و نقشه فقط یک ورونوی ساده نشان می‌دهد.
  const patients = [];
  for (let i = 1; i <= patientCount; i++) {
    const norm = rng() < 0.78;
    const ri = (lo, hi) => lo + Math.floor(rng() * (hi - lo + 1));
    const v = {
      rr: norm ? ri(12, 20) : ri(6, 34),
      spo2: norm ? ri(96, 100) : ri(84, 95),
      sbp: norm ? ri(111, 160) : ri(70, 215),
      hr: norm ? ri(55, 90) : ri(38, 145),
      tempMilliC: norm ? ri(36200, 37800) : ri(35200, 39600),
      avpu: rng() < 0.97 ? 0 : 1,
    };
    v.onOxygen = v.spo2 < 93 ? 1 : 0;
    const flags = rng() < 0.88 ? 0 : (1 << ri(0, 7));
    const ageYears = ri(16, 92);

    const n = news2(v);
    const t = triage(n, flags, ageYears);
    patients.push({
      id: `patient-${i}`, x: rand(), y: rand(),
      vitals: v, flags, ageYears,
      news2: n.total, riskBand: n.riskBand,
      triageLevel: t.level, need: t.need,
      needNames: capabilityNames(t.need),
      windowSec: GOLDEN_WINDOW[t.level],
    });
  }

  return { seed: realSeed, areaMeters, facilities, patients };
}

/* ── ارجاع ───────────────────────────────────────────
   قرینه assignNearest در نسخه 6G. تفاوت: نزدیک‌ترین کافی نیست —
   مرکز باید توانمندی لازم را داشته باشد و در پنجره طلایی باشد.
   پس بعضی بیماران هیچ مرکزی نمی‌گیرند، و این خطا نیست. */
function assignFacility(topology, { trackBeds = false } = {}) {
  const { facilities, patients } = topology;
  const load = {}; const beds = {};
  for (const f of facilities) { load[f.id] = 0; beds[f.id] = f.usedBeds; }

  const assigned = []; const rejected = [];

  for (const p of patients) {
    let best = null; let bestTravel = Infinity;
    let eligible = 0; let inWindow = 0;

    for (const f of facilities) {
      if ((p.need & ~f.capability) !== 0) continue;
      eligible++;

      const dx = p.x - f.x, dy = p.y - f.y;
      const straight = Math.floor(Math.sqrt(dx * dx + dy * dy));
      const travel = travelTimeSec(straight, f.speedKmh, f.congestion, 180);
      if (travel > p.windowSec) continue;
      inWindow++;

      if (trackBeds && f.totalBeds > 0 && beds[f.id] >= f.totalBeds) continue;

      // تساوی روی شناسه شکسته می‌شود — همان قید clinical.go، تا
      // نقشه همان مرکزی را نشان دهد که قرارداد انتخاب می‌کند.
      if (travel < bestTravel || (travel === bestTravel && best && f.id < best.id)) {
        best = f; bestTravel = travel;
      }
    }

    if (best) {
      load[best.id]++;
      if (trackBeds) beds[best.id]++;
      assigned.push({ ...p, facilityId: best.id, orgNum: best.orgNum,
                      travelSec: bestTravel, reason: 0, reasonText: REJECT[0] });
    } else {
      const reason = eligible === 0 ? 2 : inWindow === 0 ? 3 : 4;
      rejected.push({ ...p, facilityId: null, orgNum: null,
                      reason, reasonText: REJECT[reason] });
    }
  }

  const perFacility = facilities.map((f) => ({
    ...f, assignedCount: load[f.id], projectedUsed: beds[f.id],
  }));

  const byReason = {};
  for (const r of rejected) byReason[r.reasonText] = (byReason[r.reasonText] || 0) + 1;

  return {
    assigned, rejected, perFacility, byReason,
    acceptanceRate: patients.length ? assigned.length / patients.length : 0,
  };
}

/* ── ساخت آرگومان تراکنش ────────────────────────────── */
function buildArgs(contract, patient, idx) {
  const def = CONTRACT_FN[contract];
  if (!def) return null;
  const commit = `sc${String(idx).padStart(14, '0')}`;
  const v = patient.vitals || {};

  return def.params.map((p) => {
    switch (p) {
      case 'id':              return `${contract.toLowerCase()}-sc-${idx}`;
      case 'patientCommit':
      case 'recipientCommit': return commit;
      case 'x':               return String(patient.x);
      case 'y':               return String(patient.y);
      case 'rr':              return String(v.rr);
      case 'spo2':            return String(v.spo2);
      case 'onOxygen':        return String(v.onOxygen);
      case 'sbp':             return String(v.sbp);
      case 'hr':              return String(v.hr);
      case 'avpu':            return String(v.avpu);
      case 'tempMilliC':      return String(v.tempMilliC);
      case 'flags':           return String(patient.flags);
      case 'ageYears':        return String(patient.ageYears);
      case 'subject':         return patient.id;
      case 'detail':          return `triage-L${patient.triageLevel}`;
      case 'condition':       return String(patient.news2);
      case 'threshold':       return '0';
      case 'amount':          return '1000';
      case 'priceMicro':      return '500';
      default:                return `${contract.toLowerCase()}-${p}-${idx}`;
    }
  });
}

/* ── برنامه‌ریزی سناریو ──────────────────────────────── */
function planScenario({
  assignment,
  channels = ['admissionchannel'],
  includeAudit = true,
  onlyAccepted = false,
} = {}) {
  const tasks = []; const skipped = [];
  let i = 0;

  const push = (orgNum, channel, contract, patient) => {
    const def = CONTRACT_FN[contract];
    if (!def || def.readOnly) { skipped.push({ contract, reason: 'no-write-fn' }); return; }
    const args = buildArgs(contract, patient, i++);
    if (!args) { skipped.push({ contract, reason: 'no-args' }); return; }
    tasks.push({
      orgNum, channel, contract, fn: def.fn, args,
      kind: def.kind, patientId: patient.id,
      triageLevel: patient.triageLevel,
      phase: def.kind === 'ledger' ? 'audit' : 'clinical',
      // پیش‌بینی: باید بپذیرد یا رد شود؟ پس از اجرا با نتیجه واقعی
      // مقایسه کنید — واگرایی یعنی این آینه با clinical.go همگام نیست.
      expectAccept: def.kind !== 'selector' || patient.reason === 0,
    });
  };

  const population = onlyAccepted
    ? assignment.assigned
    : [...assignment.assigned, ...assignment.rejected];

  for (const ch of channels) {
    for (const p of population) {
      // بیمار ردشده مرکزی ندارد؛ از دروازه بیمارستان دولتی ارسال می‌شود
      const org = p.orgNum || 6;
      for (const contract of (CHANNEL_CHAINCODE_MAP[ch] || [])) push(org, ch, contract, p);
    }
  }

  if (includeAudit) {
    for (const p of assignment.assigned) push(p.orgNum, 'auditchannel', 'LogClinicalAudit', p);
  }

  return { tasks, skipped };
}

/* ── بررسی همگامی با هسته Go ──────────────────────────
   این آینه JS باید همان تصمیمی را بگیرد که clinical.go می‌گیرد.
   اگر واگرا شود، نقشه چیزی را نشان می‌دهد که دفتر حساب نمی‌کند و
   مدت‌ها دنبال باگ در جای اشتباه می‌گردید. مقادیر مرجع از خروجی
   واقعی آزمون Go گرفته شده‌اند. */
function assertKernelInSync() {
  const cases = [
    { v: { rr: 16, spo2: 98, onOxygen: 0, sbp: 120, hr: 70, avpu: 0, tempMilliC: 36800 }, total: 0, band: 0 },
    { v: { rr: 20, spo2: 96, onOxygen: 0, sbp: 219, hr: 90, avpu: 0, tempMilliC: 38000 }, total: 0, band: 0 },
    { v: { rr: 16, spo2: 98, onOxygen: 0, sbp: 120, hr: 35, avpu: 0, tempMilliC: 36800 }, total: 3, band: 1 },
    { v: { rr: 16, spo2: 98, onOxygen: 1, sbp: 120, hr: 70, avpu: 0, tempMilliC: 36800 }, total: 2, band: 0 },
    { v: { rr: 28, spo2: 90, onOxygen: 1, sbp: 85, hr: 135, avpu: 1, tempMilliC: 39500 }, total: 19, band: 3 },
    { v: { rr: 16, spo2: 98, onOxygen: 0, sbp: 120, hr: 70, avpu: 0, tempMilliC: 34500 }, total: 3, band: 1 },
    { v: { rr: 22, spo2: 94, onOxygen: 0, sbp: 105, hr: 95, avpu: 0, tempMilliC: 38500 }, total: 6, band: 2 },
  ];
  const diffs = [];
  for (const c of cases) {
    const r = news2(c.v);
    if (r.total !== c.total || r.riskBand !== c.band) {
      diffs.push(`NEWS2 ${JSON.stringify(c.v)} → ${r.total}/${r.riskBand}، انتظار ${c.total}/${c.band}`);
    }
  }
  // ۱۰۰۰ متر مستقیم → ۱۳۰۰ متر جاده، ۴۵km/h ≈ ۱۰۴ ثانیه + ۱۸۰ اعزام
  const t = travelTimeSec(1000, 45, 1000, 180);
  if (t < 240 || t > 320) diffs.push(`زمان سفر ${t} ثانیه — واحدها واگرا شده‌اند`);

  // پرچم بالینی باید سطح را بالا ببرد، هرگز پایین نیاورد
  const normal = news2({ rr: 16, spo2: 98, onOxygen: 0, sbp: 120, hr: 70, avpu: 0, tempMilliC: 36800 });
  if (triage(normal, FLAG.Stroke, 55).level !== 1) diffs.push('پرچم سکته باید سطح ۱ بدهد');
  if (triage(normal, 0, 55).level !== 5) diffs.push('بیمار طبیعی بدون پرچم باید سطح ۵ باشد');
  return diffs;
}

module.exports = {
  makeRng, generateTopology, assignFacility, buildArgs, planScenario,
  news2, triage, travelTimeSec, capabilityNames, assertKernelInSync,
  CAP, FLAG, CAP_LABEL, REJECT, GOLDEN_WINDOW, FACILITY_PROFILES,
  CONTRACT_FN,
  assignNearest: assignFacility, // نام قدیمی، برای scenario-routes.js
};
