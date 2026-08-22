/* ═══════════════════════════════════════════════════════════════
   catchment-map.js — نمایشگر حوزه پوشش مراکز درمانی

   جایگزین coverage-map.js پروژه 6G. ساختار دو لایه‌ای همان است:

     ۱. <canvas>  رستر «سریع‌ترین مرکز» = حوزه واقعی هر مرکز
                  (ورونوی وزن‌دار بر پایه زمان سفر، نه فاصله خام)
                  به‌علاوه مرز حوزه‌ها جایی که مالکیت عوض می‌شود
     ۲. <svg>     خطوط ارجاع، مراکز، بیماران، برچسب‌ها

   تفاوت مفهومی با نسخه 6G که مهم است:

   آنجا ورونوی بر پایه **فاصله** بود و هر نقطه از نقشه به یک آنتن
   تعلق داشت. اینجا حوزه بر پایه **زمان سفر** است (که با ضریب
   ترافیک هر مرکز وزن می‌خورد) و مهم‌تر اینکه بخش‌هایی از نقشه به
   **هیچ مرکزی** تعلق ندارند — جایی که نزدیک‌ترین مرکز واجد شرایط
   خارج از پنجره طلایی است. آن نواحی هاشور خورده نمایش داده
   می‌شوند و همان چیزی هستند که نرخ رد را می‌سازند.

   کلاس‌های موجودیت:
     مرکز درمانی   مربع، رنگ سازمان، اندازه بر حسب تعداد تخت
     بیمار پذیرفته دایره توپر، رنگ بر حسب سطح تریاژ
     بیمار ردشده   ضربدر قرمز
   ═══════════════════════════════════════════════════════════════ */

const ORG_COLORS = [
  '#35D6C4', '#F2A93B', '#E36FA8', '#6C8CFF',
  '#57D06B', '#C88BFF', '#FF8C6B', '#4FC3E8'
];

// رنگ سطح تریاژ — قرمز هرچه بحرانی‌تر
const TRIAGE_COLORS = {
  1: '#FF4D4D', 2: '#FF8C42', 3: '#F2C94C', 4: '#6FCF97', 5: '#8FA3B8'
};

function orgColor(n) { return ORG_COLORS[((n || 1) - 1) % ORG_COLORS.length]; }

function hexToRgb(hex) {
  const v = parseInt(hex.slice(1), 16);
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}

/* آینه travelTimeSec در scenario-core.js و clinical.go.
   اگر این سه واگرا شوند، نقشه حوزه‌ای را می‌کشد که قرارداد
   نمی‌شناسد. */
function travelTimeSec(straightM, speedKmh, congestionMilli, dispatchSec) {
  const roadM = Math.floor(straightM * 1300 / 1000);
  const mmPerSec = Math.floor((speedKmh || 45) * 1000 * 1000 / 3600);
  if (mmPerSec <= 0) return dispatchSec;
  const base = Math.floor(roadM * 1000 / mmPerSec);
  return dispatchSec + Math.floor(base * (congestionMilli || 1000) / 1000);
}

/**
 * رسم حوزه پوشش و نشانگرها.
 * @param {HTMLElement} stage  ظرف حاوی <canvas> و <svg>
 * @param {object} data  { areaMeters, topology:{facilities,patients},
 *                         assignment:{assigned,rejected} }
 * @param {object} [opts]  { compact, windowSec, showRejected }
 */
function renderCatchment(stage, data, opts = {}) {
  const compact = !!opts.compact;
  const showRejected = opts.showRejected !== false;
  // پنجره‌ای که رستر با آن رنگ می‌شود. پیش‌فرض سطح ۳ (یک ساعت) —
  // نقشه‌ای که با پنجره سطح ۱ کشیده شود تقریباً همه‌جا خالی است.
  const windowSec = opts.windowSec || 3600;

  const area = data.areaMeters || 30000;
  const facilities = (data.topology && data.topology.facilities) || [];
  const patients = (data.topology && data.topology.patients) || [];
  const assigned = (data.assignment && data.assignment.assigned) || [];
  const rejected = (data.assignment && data.assignment.rejected) || [];

  const canvas = stage.querySelector('canvas');
  const svg = stage.querySelector('svg');
  if (!canvas || !svg) return;

  const W = stage.clientWidth || 640;
  const H = stage.clientHeight || 480;
  const sx = (m) => (m / area) * W;
  const sy = (m) => (m / area) * H;

  /* ── لایه ۱: رستر حوزه ─────────────────────────────── */
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.round(W * dpr);
  canvas.height = Math.round(H * dpr);
  canvas.style.width = W + 'px';
  canvas.style.height = H + 'px';

  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);

  if (!facilities.length) return;

  const rgb = facilities.map((f) => hexToRgb(orgColor(f.orgNum)));
  // گام رستر: ۳ پیکسل کافی است و روی موبایل هم روان می‌ماند
  const STEP = 3;
  const owner = [];
  const cols = Math.ceil(W / STEP);
  const rows = Math.ceil(H / STEP);

  for (let r = 0; r < rows; r++) {
    owner[r] = [];
    for (let c = 0; c < cols; c++) {
      const mx = (c * STEP / W) * area;
      const my = (r * STEP / H) * area;

      let best = -1, bestT = Infinity;
      for (let i = 0; i < facilities.length; i++) {
        const f = facilities[i];
        const dx = mx - f.x, dy = my - f.y;
        const t = travelTimeSec(Math.sqrt(dx * dx + dy * dy),
                                f.speedKmh, f.congestion, 180);
        if (t < bestT) { bestT = t; best = i; }
      }

      // خارج از پنجره طلایی: به هیچ مرکزی تعلق ندارد
      if (bestT > windowSec) { owner[r][c] = -1; continue; }
      owner[r][c] = best;

      const [R, G, B] = rgb[best];
      // شفافیت با زمان سفر کم می‌شود: نزدیک مرکز پررنگ‌تر
      const alpha = 0.34 * (1 - Math.min(bestT / windowSec, 1)) + 0.06;
      ctx.fillStyle = `rgba(${R},${G},${B},${alpha.toFixed(3)})`;
      ctx.fillRect(c * STEP, r * STEP, STEP, STEP);
    }
  }

  // ناحیه بی‌پوشش: هاشور مورب. این همان چیزی است که نرخ رد را
  // می‌سازد و باید دیده شود، نه اینکه خالی بماند.
  ctx.save();
  ctx.strokeStyle = 'rgba(255,77,77,0.30)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      if (owner[r][c] !== -1) continue;
      const x = c * STEP, y = r * STEP;
      if ((c + r) % 3 === 0) { ctx.moveTo(x, y + STEP); ctx.lineTo(x + STEP, y); }
    }
  }
  ctx.stroke();
  ctx.restore();

  // مرز حوزه‌ها: جایی که مالکیت عوض می‌شود
  ctx.strokeStyle = 'rgba(255,255,255,0.22)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let r = 1; r < rows; r++) {
    for (let c = 1; c < cols; c++) {
      if (owner[r][c] !== owner[r][c - 1] || owner[r][c] !== owner[r - 1][c]) {
        ctx.moveTo(c * STEP, r * STEP);
        ctx.lineTo(c * STEP + STEP, r * STEP + STEP);
      }
    }
  }
  ctx.stroke();

  /* ── لایه ۲: نشانگرها ──────────────────────────────── */
  const NS = 'http://www.w3.org/2000/svg';
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
  svg.setAttribute('width', W);
  svg.setAttribute('height', H);
  while (svg.firstChild) svg.removeChild(svg.firstChild);

  const el = (tag, attrs) => {
    const n = document.createElementNS(NS, tag);
    for (const k in attrs) n.setAttribute(k, attrs[k]);
    return n;
  };

  // خطوط ارجاع
  if (!compact) {
    const byId = {};
    for (const f of facilities) byId[f.id] = f;
    for (const p of assigned) {
      const f = byId[p.facilityId];
      if (!f) continue;
      svg.appendChild(el('line', {
        x1: sx(p.x), y1: sy(p.y), x2: sx(f.x), y2: sy(f.y),
        stroke: orgColor(f.orgNum), 'stroke-width': 0.7, opacity: 0.42,
      }));
    }
  }

  // بیماران ردشده — ضربدر، پیش از مراکز تا زیرشان بمانند
  if (showRejected) {
    for (const p of rejected) {
      const x = sx(p.x), y = sy(p.y), s = 3.5;
      const g = el('g', { opacity: 0.85 });
      g.appendChild(el('line', { x1: x - s, y1: y - s, x2: x + s, y2: y + s,
                                stroke: '#FF4D4D', 'stroke-width': 1.6 }));
      g.appendChild(el('line', { x1: x - s, y1: y + s, x2: x + s, y2: y - s,
                                stroke: '#FF4D4D', 'stroke-width': 1.6 }));
      const t = el('title', {});
      t.textContent = `${p.id} — سطح ${p.triageLevel} — ${p.reasonText}`;
      g.appendChild(t);
      svg.appendChild(g);
    }
  }

  // بیماران پذیرفته — دایره، رنگ بر حسب سطح تریاژ
  for (const p of assigned) {
    const c = el('circle', {
      cx: sx(p.x), cy: sy(p.y),
      r: p.triageLevel <= 2 ? 3.6 : 2.6,
      fill: TRIAGE_COLORS[p.triageLevel] || '#8FA3B8',
      stroke: 'rgba(0,0,0,0.35)', 'stroke-width': 0.6,
    });
    const t = el('title', {});
    t.textContent = `${p.id} — سطح ${p.triageLevel} — NEWS2 ${p.news2}`
      + ` — ${p.facilityId} — ${Math.round(p.travelSec / 60)} دقیقه`;
    c.appendChild(t);
    svg.appendChild(c);
  }

  // مراکز — مربع، اندازه بر حسب تعداد تخت
  const maxBeds = Math.max(...facilities.map((f) => f.totalBeds || 1), 1);
  for (const f of facilities) {
    const size = 8 + 10 * Math.sqrt((f.totalBeds || 1) / maxBeds);
    const x = sx(f.x) - size / 2, y = sy(f.y) - size / 2;

    const g = el('g', {});
    g.appendChild(el('rect', {
      x, y, width: size, height: size, rx: 2,
      fill: orgColor(f.orgNum), stroke: '#0b0f14', 'stroke-width': 1.4,
    }));
    // نوار اشغال روی لبه پایین
    if (f.totalBeds > 0) {
      const occ = Math.min((f.projectedUsed ?? f.usedBeds ?? 0) / f.totalBeds, 1);
      g.appendChild(el('rect', {
        x, y: y + size - 2, width: size * occ, height: 2,
        fill: occ > 0.85 ? '#FF4D4D' : '#0b0f14', opacity: 0.9,
      }));
    }
    const t = el('title', {});
    t.textContent = `${f.id} — ${f.label || ''}\n`
      + `تخت ${f.projectedUsed ?? f.usedBeds ?? 0}/${f.totalBeds}`
      + ` — ارجاع ${f.assignedCount ?? 0}\n`
      + `${(f.capabilityNames || []).join('، ')}`
      + (f.fromLedger ? '\n(چیدمان از دفتر خوانده شده)' : '\n(چیدمان محلی — از دفتر نیامده)');
    g.appendChild(t);
    svg.appendChild(g);

    if (!compact) {
      const lbl = el('text', {
        x: sx(f.x) + size / 2 + 3, y: sy(f.y) + 3,
        fill: '#cfe3f2', 'font-size': 9, 'font-family': 'inherit',
      });
      lbl.textContent = f.id.replace('facility-', 'م');
      svg.appendChild(lbl);
    }
  }

  // راهنما
  if (!compact) {
    const lg = el('g', { transform: `translate(8, ${H - 54})` });
    const bg = el('rect', { x: 0, y: 0, width: 168, height: 48, rx: 4,
                            fill: 'rgba(0,0,0,0.45)' });
    lg.appendChild(bg);
    let ty = 13;
    for (const [lvl, col] of Object.entries(TRIAGE_COLORS)) {
      if (lvl > 3) continue;
      lg.appendChild(el('circle', { cx: 10, cy: ty - 3, r: 3.4, fill: col }));
      const t = el('text', { x: 20, y: ty, fill: '#cfe3f2', 'font-size': 9 });
      t.textContent = `سطح تریاژ ${lvl}`;
      lg.appendChild(t);
      ty += 12;
    }
    const t2 = el('text', { x: 20, y: ty, fill: '#FF9E9E', 'font-size': 9 });
    t2.textContent = 'هاشور = خارج از پنجره';
    lg.appendChild(el('line', { x1: 6, y1: ty - 6, x2: 14, y2: ty - 1,
                               stroke: 'rgba(255,77,77,0.7)', 'stroke-width': 1.4 }));
    lg.appendChild(t2);
    svg.appendChild(lg);
  }
}

// نام قدیمی برای سازگاری با کدی که هنوز آن را صدا می‌زند
const renderCoverage = renderCatchment;
