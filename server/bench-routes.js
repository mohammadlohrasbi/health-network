'use strict';

/* ═══════════════════════════════════════════════════════════════════════
   bench-routes.js — the expanded benchmark API, mounted at /api/bench.

   GET  /catalog          every channel, contract, write function and
                          argument shape the network exposes
   GET  /policies         the endorsement policies a run can be measured
                          under, and which one matches the deployment
   POST /run              start a run; returns { id } straight away
   GET  /jobs             recent runs, newest first
   GET  /job/:id          one run: progress, per-target rows, summary
   POST /job/:id/cancel   stop a run after the target in flight
   GET  /job/:id/csv      per-target rows as a CSV download

   The older POST /api/test/execute route is untouched, so anything
   already pointing at it keeps working.
   ═══════════════════════════════════════════════════════════════════════ */

const express = require('express');
const runner = require('./bench-runner');
const catalogue = require('./bench-catalog');

const router = express.Router();

router.get('/catalog', (req, res) => {
  try {
    const data = catalogue.catalog();
    const drift = catalogue.assertCatalogInSync();
    res.json({
      ...data,
      // Surfaced rather than silently tolerated: if the two channel maps
      // disagree, the benchmark and the ledger pages are describing
      // different networks.
      drift: drift.length ? drift : undefined,
      market: {
        operations: Object.keys(catalogue.MARKET_FN).map((op) => ({
          operation: op,
          ...catalogue.MARKET_FN[op],
        })),
        selectorContracts: catalogue.targetsByKind("selector").length,
        ledgerContracts: catalogue.targetsByKind("ledger").length,
        note: 'Market operations are opt-in: pass includeMarket to add them '
          + 'to a selection, or marketOnly to benchmark them alone. Only the '
          + 'location-aware contracts carry the market code.',
      },
      notes: {
        needsSeed:
          'قراردادهای selector مرکز مقصد را خودشان انتخاب می‌کنند، پس چیدمان مراکز باید پیش از پذیرش هر نوشتنی موجود باشد. یک بار scripts/seed-hospital.sh را اجرا کنید.',
        readOnly:
          'GetPolicy exposes no write function.',
        seed:
          'Benchmarks send seed 42; a contract rejects a write whose seed does not match the layout it was given.',
      },
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

router.get('/policies', (req, res) => {
  res.json({
    active: 'any',
    policies: [
      {
        key: 'any',
        label: 'Matches the deployment — one endorsement',
        detail:
          "The chaincode is committed with OR('org1MSP.member', … ,'org8MSP.member'), so a single signature commits a transaction. Use this for any figure that describes this network.",
        file: runner.POLICY_FILES.any,
      },
      {
        key: 'majority',
        label: 'Stricter hypothetical — five of eight',
        detail:
          'A MAJORITY policy that is not deployed here. Useful for measuring what a stricter policy would cost, but label results as hypothetical.',
        file: runner.POLICY_FILES.majority,
      },
    ],
  });
});

router.post('/run', (req, res) => {
  try {
    const job = runner.startJob(req.body || {});
    res.status(202).json({ id: job.id, total: job.targets.length, tool: job.tool });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// Preview a selection without running it — lets the UI say "this will run
// 34 targets, about 12 minutes" before anyone commits to a sweep.
router.post('/preview', (req, res) => {
  try {
    const body = req.body || {};
    const targets = catalogue.resolveTargets(body.selection || body);
    const rate = Math.max(1, Number(body.tps) || 20);
    const txNumber = body.txNumber
      ? Number(body.txNumber)
      : Math.round(rate * (Number(body.duration) || 30));
    const repeat = Math.max(1, Number(body.repeat) || 1);
    // Rough: send time plus a fixed overhead per target for tool startup.
    const perTarget = txNumber / rate + (body.tool === 'caliper' ? 25 : 8);
    res.json({
      targets: targets.map((t) => ({
        id: t.id, channel: t.channel, contract: t.contract, fn: t.fn,
        market: !!t.market, operation: t.operation || null,
        tapeSafe: t.tapeSafe !== false, requires: t.requires || null,
      })),
      count: targets.length,
      runs: targets.length * repeat,
      txPerTarget: txNumber,
      estimatedSeconds: Math.round(targets.length * repeat * perTarget),
    });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

router.get('/jobs', (req, res) => {
  res.json({ jobs: runner.listJobs() });
});

router.get('/job/:id', (req, res) => {
  const job = runner.getJob(req.params.id);
  if (!job) return res.status(404).json({ error: 'No run with that id' });
  res.json(runner.publicJob(job));
});

router.post('/job/:id/cancel', (req, res) => {
  const job = runner.cancelJob(req.params.id);
  if (!job) return res.status(404).json({ error: 'No run with that id' });
  res.json({ id: job.id, status: 'cancelling' });
});

router.get('/job/:id/csv', (req, res) => {
  const job = runner.getJob(req.params.id);
  if (!job) return res.status(404).json({ error: 'No run with that id' });
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="bench-${job.id}.csv"`);
  res.send(runner.resultsToCsv(job));
});

module.exports = router;
