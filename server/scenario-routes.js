'use strict';

// ═══════════════════════════════════════════════════════════════
// scenario-routes.js — API سناریوی شبیه‌سازی 6G
//   GET  /api/scenario/options  → کانال‌ها و قراردادهای قابل انتخاب
//   GET  /api/scenario/last     → آخرین جای‌گذاری ذخیره‌شده (برای نقشه)
//   POST /api/scenario/execute  → اجرای سناریو و بازگرداندن توپولوژی + نتایج
// مراکز درمانی و بیماران؛ ارجاع بر پایه زمان سفر و توانمندی.
// ═══════════════════════════════════════════════════════════════

const express = require('express');
const fs = require('fs');
const path = require('path');
const { CHANNEL_CHAINCODE_MAP, CHANNEL_TEST_FN, invokeChaincode } = require('./fabric');
const { generateTopology, assignNearest, planScenario, CONTRACT_FN } = require('./scenario-core');

const router = express.Router();

// ── ماندگاری آخرین جانمایی: حافظه + دیسک (تا بعد از restart هم بماند) ──
const LAST_FILE = path.join(__dirname, 'last-scenario.json');
let lastRun = null;
try {
  if (fs.existsSync(LAST_FILE)) lastRun = JSON.parse(fs.readFileSync(LAST_FILE, 'utf8'));
} catch (_) { lastRun = null; }
function saveLast(obj) {
  lastRun = obj;
  try { fs.writeFileSync(LAST_FILE, JSON.stringify(obj)); } catch (_) { /* best-effort */ }
}

router.get('/options', (req, res) => {
  const channels = Object.entries(CHANNEL_CHAINCODE_MAP).map(([channel, chaincodes]) => ({
    channel,
    defaultChaincode: CHANNEL_TEST_FN[channel] ? CHANNEL_TEST_FN[channel].chaincode : null,
    chaincodes: chaincodes.map((cc) => {
      const meta = CONTRACT_FN[cc];
      return {
        name: cc,
        fn: meta ? meta.fn : null,
        available: !!meta && !meta.readOnly,
        reason: !meta ? 'no-write-fn' : meta.readOnly ? 'read-only' : null,
      };
    }),
  }));
  res.json({ areaMeters: 10000, orgCount: 8, channels });
});

router.get('/last', (req, res) => {
  if (!lastRun) return res.status(404).json({ error: 'هنوز هیچ سناریویی اجرا نشده است' });
  res.json(lastRun);
});

router.post('/execute', async (req, res) => {
  try {
    const {
      iotCount = 20,
      userCount = 20,
      seed = null,
      areaMeters = 10000,
      selection = [],           // [{channel, chaincodes:[...]}]
      connectEntities = true,
      concurrency = 6,
    } = req.body || {};

    if ((!Array.isArray(selection) || selection.length === 0) && !connectEntities) {
      return res.status(400).json({ error: 'حداقل یک کانال/قرارداد انتخاب کنید یا برقراری اتصال را فعال بگذارید' });
    }
    const ic = Math.max(0, Math.min(500, Number(iotCount) || 0));
    const uc = Math.max(0, Math.min(500, Number(userCount) || 0));
    const conc = Math.max(1, Math.min(16, Number(concurrency) || 6));

    // ۱) توپولوژی و تخصیص ورونوی
    const topology = generateTopology({
      seed: seed === null || seed === '' ? undefined : Number(seed),
      areaMeters: Number(areaMeters) || 10000,
      iotCount: ic,
      userCount: uc,
    });
    const assigned = assignNearest(topology);

    // ۲) برنامه‌ریزی تراکنش‌ها
    const { tasks, skipped } = planScenario({ topology, assigned, selection, connectEntities });
    if (tasks.length === 0) {
      return res.status(400).json({ error: 'هیچ تسکی ساخته نشد — انتخاب‌ها را بررسی کنید', skipped });
    }
    if (tasks.length > 5000) {
      return res.status(400).json({
        error: `تعداد تراکنش (${tasks.length}) از سقف ۵۰۰۰ بیشتر است — تعداد موجودیت‌ها یا کانال‌ها را کم کنید`,
      });
    }

    // ۳) اجرا با محدودیت همزمانی + سنجش
    const t0 = Date.now();
    const results = new Array(tasks.length);
    let idx = 0;
    async function worker() {
      while (true) {
        const i = idx++;
        if (i >= tasks.length) return;
        const task = tasks[i];
        const s = Date.now();
        try {
          await invokeChaincode(task.orgNum, task.channel, task.chaincode, task.fn, task.args);
          results[i] = { ok: true, ms: Date.now() - s, task };
        } catch (err) {
          results[i] = { ok: false, ms: Date.now() - s, task, error: String(err.message || err).slice(0, 300) };
        }
      }
    }
    await Promise.all(Array.from({ length: conc }, worker));
    const durationMs = Date.now() - t0;

    // ۴) تجمیع
    const ok = results.filter((r) => r.ok);
    const fail = results.filter((r) => !r.ok);
    const lat = ok.map((r) => r.ms);
    const agg = (arr, f) => (arr.length ? f(arr) : 0);
    const perChannel = {};
    const perKind = {};
    for (const r of results) {
      const ch = r.task.channel;
      perChannel[ch] = perChannel[ch] || { total: 0, ok: 0, fail: 0 };
      perChannel[ch].total++; perChannel[ch][r.ok ? 'ok' : 'fail']++;
      const k = r.task.kind;
      perKind[k] = perKind[k] || { total: 0, ok: 0, fail: 0 };
      perKind[k].total++; perKind[k][r.ok ? 'ok' : 'fail']++;
    }

    // مراکز درمانی و بیماران
    const payload = {
      savedAt: new Date().toISOString(),
      seed: topology.seed,
      areaMeters: topology.areaMeters,
      topology: {
        facilities: topology.facilities,
        iots: assigned.iots,
        users: assigned.users,
      },
      coverage: assigned.perOrg,          // حوزه هر مرکز: موقعیت + تعداد ارجاع
      skipped,
      performance: {
        totalTasks: tasks.length,
        successCount: ok.length,
        failedCount: fail.length,
        durationMs,
        tps: +(results.length / (durationMs / 1000)).toFixed(2),
        latency: {
          avg: +agg(lat, (a) => a.reduce((x, y) => x + y, 0) / a.length).toFixed(1),
          min: agg(lat, (a) => Math.min(...a)),
          max: agg(lat, (a) => Math.max(...a)),
        },
        perChannel,
        perKind,
        failureSamples: fail.slice(0, 5).map((r) => ({
          chaincode: r.task.chaincode, fn: r.task.fn, error: r.error,
        })),
      },
    };
    saveLast(payload);
    res.json(payload);
  } catch (err) {
    res.status(500).json({ error: String(err.message || err) });
  }
});

module.exports = router;
