'use strict';

/* ═══════════════════════════════════════════════════════════════════════
   bench-runner.js — runs a benchmark across one or many targets.

   A full 20-channel sweep takes many minutes, so a run is a background
   job: the route returns a job id immediately and the UI polls for
   progress. Targets are executed one at a time — running them
   concurrently would have them compete for the same peers and make every
   number meaningless.
   ═══════════════════════════════════════════════════════════════════════ */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFileSync } = require('child_process');
const yaml = require('js-yaml');

/* ── مسیر گواهی TLS: از دیسک، نه از فرض ─────────────────────────────
   config.js مسیرها را با نام‌گذاری cryptogen می‌سازد
   (.../orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem)
   ولی network.sh از fabric-ca استفاده می‌کند و ساختار دیگری می‌دهد
   (.../ordererOrganizations/example.com/msp/tlscacerts/ca-cert.pem).

   تا وقتی TLS خاموش بود این مسیر خوانده نمی‌شد. با TLS روشن، Tape سر آن
   می‌ایستد:  fail to load TLS CA Cert ...: no such file or directory

   پس اگر مسیری که config می‌دهد روی دیسک نبود، همان‌جا دنبال گواهی واقعی
   می‌گردیم به‌جای اینکه کانفیگی بسازیم که قطعاً شکست می‌خورد. */
function resolveTlsCert(given, orgDir) {
  if (given && fs.existsSync(given)) return given;
  try {
    const base = path.join(orgDir, 'msp', 'tlscacerts');
    const hit = fs.readdirSync(base).find((f) => f.endsWith('.pem') || f.endsWith('.crt'));
    if (hit) return path.join(base, hit);
  } catch (_) { /* پوشه نیست */ }
  return given || '';
}

/* ریشه crypto-config، برای یافتن پوشه هر سازمان. */
function cryptoBase() {
  return process.env.CRYPTO_BASE
    || path.join(__dirname, '..', 'config', 'crypto-config');
}

function orgTlsCert(o) {
  return resolveTlsCert(
    o.tlsRootCert,
    path.join(cryptoBase(), 'peerOrganizations', `${o.name || o.org || 'org1'}.example.com`)
  );
}

function ordererTlsCert() {
  return resolveTlsCert(
    config.orderer && config.orderer.tlsCaCert,
    path.join(cryptoBase(), 'ordererOrganizations', 'example.com')
  );
}

const config = require('./config');
const {
  buildArgs,
  buildKey,
  resolveTargets,
  READ_FN,
} = require('./bench-catalog');

const TEST_TOOLS_DIR =
  process.env.TEST_TOOLS_DIR || path.resolve(__dirname, '..', 'test-tools');
const CALIPER_WORKSPACE =
  process.env.CALIPER_WORKSPACE || path.join(TEST_TOOLS_DIR, 'caliper-workspace');
const TAPE_CONFIG_DIR =
  process.env.TAPE_CONFIG_DIR || path.join(TEST_TOOLS_DIR, 'tape-configs');
// Read at spawn time, not at load time, so the binary path can be changed
// without restarting the server.
const tapeBin = () => process.env.TAPE_BIN || path.join(os.homedir(), 'go', 'bin', 'tape');
/* Resolving the Caliper executable.
 *
 * `npx caliper` looked fine but fails with "could not determine executable to
 * run" when the dashboard is started by systemd: the unit's PATH usually
 * omits /usr/local/bin, which is where a global npm install puts the binary,
 * and npx with no network cannot fall back to fetching it.
 *
 * So the launcher is located explicitly instead. Each candidate is checked on
 * disk, in order, and the resolution is cached per process.
 */
let caliperCmdCache = null;

function resolveCaliper(workspace) {
  if (caliperCmdCache) return caliperCmdCache;

  if (process.env.CALIPER_BIN) {
    const explicit = process.env.CALIPER_BIN;
    caliperCmdCache = explicit.endsWith('.js')
      ? { cmd: process.execPath, prefix: [explicit] }
      : { cmd: explicit, prefix: [] };
    return caliperCmdCache;
  }

  // A launcher script: invoked directly, with "caliper" already implied.
  const scripts = [
    path.join(workspace, 'node_modules', '.bin', 'caliper'),
    '/usr/local/bin/caliper',
    '/usr/bin/caliper',
    path.join(os.homedir(), '.npm-global', 'bin', 'caliper'),
  ];
  for (const p of scripts) {
    if (fs.existsSync(p)) {
      caliperCmdCache = { cmd: p, prefix: [] };
      return caliperCmdCache;
    }
  }

  // The CLI entry point: run it with this process's own node, so the result
  // does not depend on PATH at all.
  const entries = [
    '/usr/local/lib/node_modules/@hyperledger/caliper-cli/caliper.js',
    '/usr/lib/node_modules/@hyperledger/caliper-cli/caliper.js',
    path.join(os.homedir(), '.npm-global', 'lib', 'node_modules',
      '@hyperledger', 'caliper-cli', 'caliper.js'),
    path.join(workspace, 'node_modules', '@hyperledger', 'caliper-cli', 'caliper.js'),
  ];
  for (const p of entries) {
    if (fs.existsSync(p)) {
      caliperCmdCache = { cmd: process.execPath, prefix: [p] };
      return caliperCmdCache;
    }
  }

  return null;
}
const RUN_DIR = process.env.BENCH_RUN_DIR || path.join(TEST_TOOLS_DIR, 'bench-runs');

/* ── Endorsement policy ───────────────────────────────────────────────
   The deployed chaincode policy is OR(org1..org8) — a single signature
   commits. Tape needs a matching rego file or it will keep collecting
   endorsements the network never asked for, which inflates its latency
   and makes Tape/Caliper results incomparable.

   'any'      — count(input) >= 1, mirrors the deployed policy (default)
   'majority' — count(input) >= 5, the stricter hypothetical
                configuration, kept so both can be measured.            */
const POLICY_FILES = {
  any: 'endorsement-any.rego',
  majority: 'endorsement-majority.rego',
};

const POLICY_SOURCE = {
  any: `package tape

default allow = false

# Mirrors the deployed chaincode policy:
#   OR('org1MSP.member', ... ,'org8MSP.member')
# A single endorsement satisfies it.
allow {
    count(input) >= 1
}
`,
  majority: `package tape

default allow = false

# Hypothetical stricter policy: MAJORITY of 8 organizations.
# This is NOT what is deployed on the network — use it only for the
# deliberate policy-cost comparison, and say so when reporting results.
allow {
    count(input) >= 5
}
`,
};

/** Write both rego files if absent, return the path of the selected one. */
function ensurePolicyFile(policy = 'any') {
  const key = POLICY_FILES[policy] ? policy : 'any';
  fs.mkdirSync(TAPE_CONFIG_DIR, { recursive: true });
  for (const [name, file] of Object.entries(POLICY_FILES)) {
    const p = path.join(TAPE_CONFIG_DIR, file);
    if (!fs.existsSync(p)) fs.writeFileSync(p, POLICY_SOURCE[name], 'utf8');
  }
  return path.join(TAPE_CONFIG_DIR, POLICY_FILES[key]);
}

/* ── Crypto material ─────────────────────────────────────────────────── */

function firstFileIn(dir) {
  const files = fs.readdirSync(dir).filter((f) => !f.startsWith('.')).sort();
  if (!files.length) throw new Error(`No files in ${dir}`);
  return path.join(dir, files[0]);
}

/* ── Tape ────────────────────────────────────────────────────────────── */

/**
 * Build a tape config for one target.
 * `endorsers` decides how many organizations are asked to endorse — with
 * the 'any' policy one is enough, which is what the network actually
 * requires; more endorsers measures the cost of a stricter policy.
 */
function buildTapeConfig({ target, orgNums, policyPath, connections, clientsPerConn, keyPrefix }) {
  const endorsers = orgNums.map((n) => {
    const o = config.getOrg(n);
    if (!o) throw new Error(`Org ${n} is not in the server config`);
    return {
      addr: o.peerEndpoint,
      tls_ca_cert: config.tlsEnabled ? orgTlsCert(o) : '',
      org: `org${n}`,
    };
  });

  const signer = config.getOrg(orgNums[0]);

  return {
    endorsers,
    committers: [
      {
        addr: signer.peerEndpoint,
        tls_ca_cert: config.tlsEnabled ? orgTlsCert(signer) : '',
        org: `org${orgNums[0]}`,
      },
    ],
    commitThreshold: 1,
    orderer: {
      addr: config.orderer.endpoint,
      tls_ca_cert: config.tlsEnabled ? ordererTlsCert() : '',
      org: `org${orgNums[0]}`,
    },
    policyFile: policyPath,
    channel: target.channel,
    chaincode: target.contract,
    args: [target.fn, ...buildArgs(target.contract, 1, keyPrefix, target.operation)],
    mspid: signer.mspId,
    private_key: firstFileIn(signer.adminKeyDir),
    sign_cert: firstFileIn(signer.adminCertDir),
    num_of_conn: connections,
    client_per_conn: clientsPerConn,
  };
}

// Tape's real output, confirmed against a live run:
//
//   Time     7.03s\tBlock     56\tTx    500
//   From Orderer Time     8.12s\tBlock     59\t Tx     75
//   tx: 1000, duration: 8.464269379s, tps: 118.143688
//
// The last line is the summary. Note what is NOT there: tape reports no
// per-transaction latency in this format, so latency is left unset rather
// than filled with a zero that would read as "instant". Use Caliper when
// latency is the question — that division is why both tools are here.
function parseTape(text) {
  const m = {
    tps: NaN,
    latencyAvg: NaN,
    latencyMin: NaN,
    latencyMax: NaN,
    successCount: NaN,
    failedCount: NaN,
    durationSec: NaN,
    blockCount: NaN,
    avgBlockSize: NaN,
    roundError: null,
  };
  // gRPC keepalive: the peer closes the connection when pings arrive faster
  // than CORE_PEER_KEEPALIVE_MININTERVAL allows. It surfaces when every
  // transaction is rejected, because tape then cycles far faster than it
  // would while waiting for commits — so the real fault is usually upstream.
  if (/too_many_pings|ENHANCE_YOUR_CALM/.test(text)) {
    m.roundError = 'the peer closed the connection for sending gRPC pings too '
      + 'quickly. This normally follows every transaction being rejected — read '
      + 'the chaincode error above it. If the run was otherwise healthy, lower '
      + 'the connection or client count.';
  }


  const summary = text.match(/tx:\s*(\d+),\s*duration:\s*([\d.]+)s,\s*tps:\s*([\d.]+)/i);
  if (summary) {
    m.successCount = parseInt(summary[1], 10);
    m.durationSec = parseFloat(summary[2]);
    m.tps = parseFloat(summary[3]);
    // Tape sends a fixed number and reports how many landed in blocks.
    m.failedCount = 0;
  }

  // Block lines, deduplicated — each block is announced twice, once by the
  // orderer and once on commit. Block size distribution is worth keeping:
  // it shows whether the orderer is batching or starving.
  const blocks = new Map();
  for (const b of text.matchAll(/Block\s+(\d+)\s*\t?\s*Tx\s+(\d+)/gi)) {
    blocks.set(parseInt(b[1], 10), parseInt(b[2], 10));
  }
  if (blocks.size) {
    m.blockCount = blocks.size;
    const sizes = [...blocks.values()];
    m.avgBlockSize = sizes.reduce((a, c) => a + c, 0) / sizes.length;
    if (!Number.isFinite(m.successCount)) {
      m.successCount = sizes.reduce((a, c) => a + c, 0);
    }
  }

  // Older tape builds do print latency; keep reading it when present.
  const last = (re) => {
    const all = [...text.matchAll(re)];
    return all.length ? parseFloat(all[all.length - 1][1]) : NaN;
  };
  const avg = last(/(?:avg|average)\s*latency[:\s]+([\d.]+)/gi);
  if (Number.isFinite(avg)) {
    m.latencyAvg = avg;
    m.latencyMin = last(/min\s*latency[:\s]+([\d.]+)/gi);
    m.latencyMax = last(/max\s*latency[:\s]+([\d.]+)/gi);
  }
  if (!Number.isFinite(m.tps)) m.tps = last(/tps[:\s]+([\d.]+)/gi);

  return m;
}

function runTapeTarget(target, opts, job) {
  return new Promise((resolve) => {
    const cfgPath = path.join(
      RUN_DIR, job.id, `tape-${target.channel}-${target.contract}.yaml`);
    let child;
    try {
      const cfg = buildTapeConfig({
        target,
        orgNums: opts.orgNums,
        policyPath: opts.policyPath,
        connections: opts.connections,
        clientsPerConn: opts.clientsPerConn,
        keyPrefix: opts.keyPrefix,
      });
      fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
      fs.writeFileSync(cfgPath, yaml.dump(cfg), 'utf8');
    } catch (err) {
      return resolve({ ok: false, error: `Could not write the tape config: ${err.message}` });
    }

    const args = ['-c', cfgPath, '-n', String(opts.txNumber)];
    if (opts.rate) args.push('--rate', String(opts.rate));
    if (opts.burst) args.push('--burst', String(opts.burst));

    let out = '';
    try {
      child = spawn(tapeBin(), args, {
        env: { ...process.env, CORE_PEER_TLS_ENABLED: String(config.tlsEnabled) },
      });
    } catch (err) {
      return resolve({ ok: false, error: `Could not start tape: ${err.message}` });
    }

    job._children.add(child);
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch (_) { /* already gone */ }
    }, opts.timeoutMs);

    child.stdout.on('data', (d) => { out += d.toString(); });
    child.stderr.on('data', (d) => { out += d.toString(); });
    child.on('error', (err) => {
      clearTimeout(timer);
      job._children.delete(child);
      resolve({ ok: false, error: `tape could not run: ${err.message}` });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      job._children.delete(child);
      const m = parseTape(out);
      // قرارداد selector تا وقتی چیدمان مراکز نداشته باشد هر نوشتنی را رد می‌کند
      // exists. That reads as a flat failure unless it is named.
      const unseeded = /SeedFacilityLayout|بذرکاری نشده|هیچ مرکزی بذرکاری نشده/i.test(out);
      resolve({
        ok: code === 0,
        exitCode: code,
        metrics: m,
        output: out.split('\n').slice(-40).join('\n'),
        error: code === 0 ? null
          : unseeded
            ? `${target.contract} چیدمان مراکز ندارد — scripts/seed-hospital.sh را اجرا کنید`
            : `tape exited with code ${code}`,
        configPath: cfgPath,
      });
    });
  });
}

/* ── Caliper ──────────────────────────────────────────────────────────
   Rather than relying on pre-generated per-function assets, the
   benchmark file is written per target at run time and points at one
   generic workload module. That way every one of the 90 targets is
   reachable without keeping 61 near-identical files in sync.          */

function buildCaliperBenchmark(target, opts) {
  const rounds = [{
    label: `write-${target.operation || target.contract}`,
    txNumber: opts.txNumber,
    rateControl: { type: 'fixed-rate', opts: { tps: opts.rate } },
    workload: {
      module: 'workload/generic-write.js',
      arguments: {
        // Caliper addresses the contract by its unique alias; the plain
        // name goes along so the workload can look up the argument shape.
        contractId: target.caliperId,
        contractName: target.contract,
        contractFunction: target.fn,
        // A market target overrides the contract's own write function, so
        // the workload builds arguments for the operation rather than for
        // the contract.
        marketOperation: target.operation || '',
        params: target.params,
        keyPrefix: opts.keyPrefix,
        mspId: config.getOrg(opts.orgNums[0]).mspId,
      },
    },
  }];

  if (opts.readPhase) {
    rounds.push({
      label: `read-${target.contract}`,
      txNumber: opts.txNumber,
      rateControl: { type: 'fixed-rate', opts: { tps: opts.readRate || opts.rate * 2 } },
      workload: {
        module: 'workload/generic-read.js',
        arguments: {
          contractId: target.caliperId,
          contractName: target.contract,
          contractFunction: READ_FN,
          keyPrefix: opts.keyPrefix,
          keySpace: opts.txNumber,
          mspId: config.getOrg(opts.orgNums[0]).mspId,
        },
      },
    });
  }

  return {
    test: {
      name: `${target.channel}-${target.contract}`,
      description: `Benchmark of ${target.fn} on ${target.channel}`,
      workers: { number: opts.workers },
      rounds,
    },
    monitors: {
      resource: [{
        module: 'docker',
        options: {
          interval: 5,
          containers: [
            `peer0.org${opts.orgNums[0]}.example.com`,
            'orderer.example.com',
          ],
        },
      }],
    },
  };
}

/* Caliper's result table, one row per round:

     | write-Contract | 486  | 14   | 20.1 | 1.94 | 0.09 | 0.41 | 19.8 |
       label            succ   fail   send   max    min    avg    tps

   Latency columns are seconds and are converted to milliseconds here.

   Parsing is deliberately strict — anchored on a full eight-cell row.
   A loose fallback previously matched "Benchmark successfully finished"
   and then swallowed the first digits of the NEXT log line, which is the
   year, so failed rounds were reported as 2026 committed transactions. A
   benchmark that invents numbers is worse than one that reports nothing,
   so when no table is present this returns no counts at all. */
function parseCaliper(text) {
  const m = {
    tps: NaN,
    latencyAvg: NaN,
    latencyMin: NaN,
    latencyMax: NaN,
    successCount: NaN,
    failedCount: NaN,
    roundError: null,
  };

  // Caliper says so explicitly when a round dies; keep the reason.
  const failed = text.match(/Failed round\s+\d+\s*\(([^)]*)\):\s*(.+)/);
  if (failed) {
    m.roundError = failed[2].split('\n')[0].replace(/^Error:\s*/, '').trim();
  }

  const rows = [...text.matchAll(
    /^\s*\|([^|\n]+)\|([^|\n]+)\|([^|\n]+)\|([^|\n]+)\|([^|\n]+)\|([^|\n]+)\|([^|\n]+)\|([^|\n]+)\|\s*$/gm)]
    .map((r) => r.slice(1).map((c) => c.trim()))
    // Drop the header and the +---+ separators. Succ, Fail and Send Rate are
    // always numeric; the three latency columns print as "-" when a round
    // committed nothing, which is exactly the case worth reporting. Requiring
    // numbers everywhere threw that row away and left the run looking like
    // Caliper had produced no table at all.
    .filter((c) => {
      if (c.length < 8) return false;
      const numeric = (v) => v !== '' && Number.isFinite(Number(v));
      const dashOrNumeric = (v) => v === '-' || numeric(v);
      return numeric(c[1]) && numeric(c[2]) && numeric(c[3])
        && dashOrNumeric(c[4]) && dashOrNumeric(c[5]) && dashOrNumeric(c[6])
        && numeric(c[7]);
    });

  if (!rows.length) {
    if (!m.roundError) {
      // npm-level failures never reach Caliper's own error reporting, so they
      // have to be recognised here or the operator only sees "no result
      // table" and has nothing to act on.
      if (/could not determine executable to run/i.test(text)) {
        m.roundError = 'The Caliper CLI could not be launched — npx found no '
          + 'caliper executable. Install it globally, or set CALIPER_BIN.';
      } else {
        const npmErr = text.match(/npm ERR!\s*(.+)/);
        const generic = text.match(/error code:\s*(\d+)/i);
        m.roundError = npmErr
          ? `npm could not start Caliper: ${npmErr[1].trim()}`
          : generic
            ? `Caliper reported no results (error code ${generic[1]})`
            : 'Caliper produced no result table';
      }
    }
    return m;
  }

  // With a read round configured there are two rows; the write round is
  // the one that describes commit throughput.
  const row = rows.find((c) => /^write-/.test(c[0])) || rows[0];
  const ms = (v) => (v === '-' ? NaN : Number(v) * 1000);
  m.successCount = Number(row[1]);
  m.failedCount = Number(row[2]);
  m.latencyMax = ms(row[4]);
  m.latencyMin = ms(row[5]);
  m.latencyAvg = ms(row[6]);
  m.tps = Number(row[7]);

  // Caliper reports send rate as throughput when nothing commits, which reads
  // as a healthy figure next to a column of zeros. Throughput is what landed
  // on the ledger, so with no successes it is zero.
  if (m.successCount === 0) {
    m.tps = 0;
    m.roundError = m.roundError
      || `every transaction was rejected (${m.failedCount} of ${m.failedCount}) — `
         + 'open the tool output for the chaincode error';
  }

  const read = rows.find((c) => /^read-/.test(c[0]));
  if (read) {
    m.readTps = Number(read[1]) === 0 ? 0 : Number(read[7]);
    m.readLatencyAvg = ms(read[6]);
    m.readSuccessCount = Number(read[1]);
  }

  return m;
}

function runCaliperTarget(target, opts, job) {
  return new Promise((resolve) => {
    const benchPath = path.join(
      RUN_DIR, job.id, `caliper-${target.channel}-${target.contract}.yaml`);
    const netPath = path.join(
      CALIPER_WORKSPACE, 'networks', `org${opts.orgNums[0]}.yaml`);

    const assetError = ensureCaliperAssets(opts.orgNums[0]);
    if (assetError) return resolve({ ok: false, error: assetError });

    try {
      fs.mkdirSync(path.dirname(benchPath), { recursive: true });
      fs.writeFileSync(benchPath, yaml.dump(buildCaliperBenchmark(target, opts)), 'utf8');
    } catch (err) {
      return resolve({ ok: false, error: `Could not write the benchmark file: ${err.message}` });
    }

    const launcher = resolveCaliper(CALIPER_WORKSPACE);
    if (!launcher) {
      return resolve({
        ok: false,
        error: 'Could not find the Caliper CLI. Install it with: '
          + 'npm install -g --unsafe-perm @hyperledger/caliper-cli@0.6.0 '
          + '— or set CALIPER_BIN to its path.',
      });
    }

    const args = [
      ...launcher.prefix,
      'launch', 'manager',
      '--caliper-workspace', CALIPER_WORKSPACE,
      '--caliper-networkconfig', netPath,
      '--caliper-benchconfig', benchPath,
      '--caliper-flow-only-test',
    ];

    let out = '';
    let child;
    try {
      child = spawn(launcher.cmd, args, {
        cwd: CALIPER_WORKSPACE,
        env: { ...process.env, CORE_PEER_TLS_ENABLED: String(config.tlsEnabled) },
      });
    } catch (err) {
      return resolve({ ok: false, error: `Could not start caliper: ${err.message}` });
    }

    job._children.add(child);
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch (_) { /* already gone */ }
    }, opts.timeoutMs);

    child.stdout.on('data', (d) => { out += d.toString(); });
    child.stderr.on('data', (d) => { out += d.toString(); });
    child.on('error', (err) => {
      clearTimeout(timer);
      job._children.delete(child);
      resolve({ ok: false, error: `caliper could not run: ${err.message}` });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      job._children.delete(child);
      const m = parseCaliper(out);
      // Caliper exits 0 even when every round failed, so the presence of
      // results decides the outcome, not the exit code.
      const produced = Number.isFinite(m.successCount);
      resolve({
        ok: code === 0 && produced,
        exitCode: code,
        metrics: m,
        output: out.split('\n').slice(-60).join('\n'),
        error: produced
          ? (code === 0 ? null : `caliper exited with code ${code}`)
          : /SeedFacilityLayout|بذرکاری نشده|هیچ مرکزی بذرکاری نشده/i.test(out)
            ? `${target.contract} چیدمان مراکز ندارد — scripts/seed-hospital.sh را اجرا کنید`
            : (m.roundError || `caliper exited with code ${code}`),
        configPath: benchPath,
      });
    });
  });
}

/* ── Self-healing asset generation ────────────────────────────────────
   The Caliper workload and network files are pure code generation from
   the catalog — nothing about them is hand-edited, and nothing outside
   this repository is needed to rebuild them. So when they are missing,
   rebuild them instead of failing and asking the operator to run a
   script. This removes a whole class of "works after you also run X"
   support round-trips.                                                 */

const REPO_ROOT = path.resolve(__dirname, '..');

function regenerate(script, label) {
  const file = path.join(REPO_ROOT, 'scripts', script);
  if (!fs.existsSync(file)) {
    return `${label} are missing and ${file} is not there to rebuild them.`;
  }
  try {
    execFileSync(process.execPath, [file, '--workspace', CALIPER_WORKSPACE], {
      cwd: REPO_ROOT,
      timeout: 120_000,
      stdio: 'pipe',
    });
    return null;
  } catch (err) {
    const detail = (err.stderr || err.stdout || '').toString().trim().split('\n').slice(-3).join(' ');
    return `${label} are missing and could not be rebuilt: ${detail || err.message}`;
  }
}

/** Make sure the workload modules and network config exist. */
function ensureCaliperAssets(orgNum) {
  const workload = path.join(CALIPER_WORKSPACE, 'workload', 'generic-write.js');
  if (!fs.existsSync(workload)) {
    const err = regenerate('gen-caliper-assets.js', 'Caliper workloads');
    if (err) return err;
    if (!fs.existsSync(workload)) {
      return `Caliper workloads were rebuilt but ${workload} still is not there.`;
    }
  }

  const net = path.join(CALIPER_WORKSPACE, 'networks', `org${orgNum}.yaml`);
  if (!fs.existsSync(net)) {
    const err = regenerate('gen-caliper-network.js', 'Caliper network configuration');
    if (err) return err;
    if (!fs.existsSync(net)) {
      return `Caliper network configuration was rebuilt but ${net} still is not there. `
        + 'Check that crypto material exists for that organization.';
    }
  }

  return null;
}

/* ── Job store ────────────────────────────────────────────────────────
   In memory, capped. Jobs do not need to survive a restart — the CSV of
   any finished run is written to disk under bench-runs/<id>/.          */

const jobs = new Map();
const JOB_LIMIT = 40;

function newJobId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
}

function trimJobs() {
  while (jobs.size > JOB_LIMIT) {
    const oldest = jobs.keys().next().value;
    jobs.delete(oldest);
  }
}

function publicJob(job) {
  return {
    id: job.id,
    tool: job.tool,
    status: job.status,
    startedAt: job.startedAt,
    finishedAt: job.finishedAt,
    options: job.options,
    selection: job.selection,
    total: job.targets.length,
    completed: job.results.length,
    current: job.current,
    results: job.results,
    summary: job.summary,
    waves: job.waves,
    error: job.error,
  };
}

/** Aggregate per-target results into one headline set of figures. */
function summarize(results, job) {
  const done = results.filter((r) => r.ok);
  const committed = results.reduce((n, r) => n + (r.successCount || 0), 0);
  const rejected = results.reduce((n, r) => n + (r.failedCount || 0), 0);
  const tpsList = done.map((r) => r.tps).filter(Number.isFinite);
  const latList = done.map((r) => r.latencyAvg).filter(Number.isFinite);
  const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0);
  const ranked = done
    .filter((r) => Number.isFinite(r.tps) && r.tps > 0)
    .sort((a, b) => b.tps - a.tps);
  const best = ranked[0];
  const worst = ranked[ranked.length - 1];
  return {
    targetsRun: results.length,
    targetsOk: done.length,
    targetsFailed: results.length - done.length,
    committed,
    rejected,
    successRate: committed + rejected ? (committed / (committed + rejected)) * 100 : 0,
    tpsMean: mean(tpsList),
    tpsMax: tpsList.length ? Math.max(...tpsList) : 0,
    tpsMin: tpsList.length ? Math.min(...tpsList) : 0,
    latencyMean: mean(latList),
    fastestTarget: best ? best.id : null,
    slowestTarget: worst ? worst.id : null,
    ...waveSummary(job),
  };
}

/* Aggregate figures across waves.
 *
 * aggregateTps is what the network actually carried; sumOfTargetTps is what
 * the targets each reported. With concurrency of 1 they agree. Above that,
 * the gap between them is the measurement: if the network scales, the
 * aggregate rises with the wave width; if it saturates, the aggregate flat-
 * tens while each target's own rate falls.
 */
function waveSummary(job) {
  if (!job || !job.waves || !job.waves.length) return {};
  const widths = new Set(job.waves.map((w) => w.size));
  const agg = job.waves.map((w) => w.aggregateTps).filter(Number.isFinite);
  const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0);
  return {
    concurrency: Math.max(...job.waves.map((w) => w.size)),
    waveCount: job.waves.length,
    mixedWidths: widths.size > 1,
    aggregateTpsMean: mean(agg),
    aggregateTpsMax: agg.length ? Math.max(...agg) : 0,
  };
}

function resultsToCsv(job) {
  const head = [
    'run_id', 'tool', 'policy', 'repeat', 'channel', 'contract', 'function',
    'org', 'target_tps', 'tx_number', 'workers', 'endorsers',
    'throughput_tps', 'duration_s', 'blocks', 'avg_block_size',
    'latency_avg_ms', 'latency_min_ms', 'latency_max_ms',
    'committed', 'rejected', 'ok', 'error',
  ].join(',');
  const esc = (v) => {
    const s = v === null || v === undefined ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const rows = job.results.map((r) => [
    job.id, job.tool, job.options.policy, r.repeat, r.channel, r.contract, r.fn,
    job.options.orgNums.join('|'), job.options.rate, job.options.txNumber,
    job.options.workers, job.options.orgNums.length,
    r.tps, r.durationSec, r.blockCount, r.avgBlockSize,
    r.latencyReported ? r.latencyAvg : '', r.latencyReported ? r.latencyMin : '',
    r.latencyReported ? r.latencyMax : '',
    r.successCount, r.failedCount, r.ok, r.error,
  ].map(esc).join(','));
  return [head, ...rows].join('\n');
}

/* ── Orchestration ───────────────────────────────────────────────────── */

function normalizeOptions(body = {}) {
  const orgNums = Array.isArray(body.orgs) && body.orgs.length
    ? body.orgs.map(Number).filter((n) => n >= 1 && n <= 8)
    : [Number(body.org) || 1];
  if (!orgNums.length) throw new Error('Pick at least one organization');

  const rate = Math.max(1, Math.min(5000, Number(body.tps) || 20));
  const txNumber = body.txNumber
    ? Math.max(1, Math.min(200000, Number(body.txNumber)))
    : Math.max(1, Math.round(rate * (Number(body.duration) || 30)));

  return {
    policy: POLICY_FILES[body.policy] ? body.policy : 'any',
    orgNums,
    rate,
    txNumber,
    workers: Math.max(1, Math.min(16, Number(body.workers) || 2)),
    repeat: Math.max(1, Math.min(10, Number(body.repeat) || 1)),
    // How many targets run at once. 1 measures each contract in isolation;
    // higher values put several channels under load together, which is what
    // a live network looks like. Capped at 32 — each Caliper target starts
    // its own worker processes, and a 4 GB host runs out well before that.
    concurrency: Math.max(1, Math.min(32, Number(body.concurrency) || 1)),
    readPhase: !!body.readPhase,
    readRate: Number(body.readTps) || 0,
    burst: Number(body.burst) || 0,
    connections: Math.max(1, Math.min(64, Number(body.connections) || 8)),
    clientsPerConn: Math.max(1, Math.min(64, Number(body.clientsPerConn) || 10)),
    keyPrefix: (body.keyPrefix || 'bench').replace(/[^A-Za-z0-9_-]/g, ''),
    timeoutMs: Math.max(30_000, Math.min(3_600_000, Number(body.timeoutMs) || 600_000)),
  };
}

/**
 * Start a benchmark job. Returns the job id immediately; the run
 * continues in the background.
 */
function startJob(body = {}) {
  const tool = body.tool === 'caliper' ? 'caliper' : 'tape';
  const options = normalizeOptions(body);
  const targets = resolveTargets(body.selection || body);

  if (!targets.length) {
    throw new Error(
      'That selection produced no runnable targets. Read-only contracts are excluded unless you include them.');
  }

  options.policyPath = ensurePolicyFile(options.policy);

  const job = {
    id: newJobId(),
    tool,
    status: 'running',
    startedAt: new Date().toISOString(),
    finishedAt: null,
    options,
    selection: body.selection || { mode: body.mode },
    targets,
    results: [],
    current: null,
    summary: null,
    error: null,
    cancelled: false,
    waves: [],
    _children: new Set(),
  };

  jobs.set(job.id, job);
  trimJobs();
  fs.mkdirSync(path.join(RUN_DIR, job.id), { recursive: true });

  // Kick off without blocking the response.
  runJob(job).catch((err) => {
    job.status = 'failed';
    job.error = err.message;
    job.finishedAt = new Date().toISOString();
  });

  return job;
}

/* Running one target.
   Split out of the loop so a wave of targets can be started together —
   see runJob. */
async function runOneTarget(job, target, rep, runner) {
  const { options, tool } = job;

  // A distinct prefix per repeat keeps each pass writing fresh keys.
  // Under concurrency it also keeps waves from colliding with each other.
  const opts = {
    ...options,
    keyPrefix: options.repeat > 1
      ? `${options.keyPrefix}${rep}`
      : options.keyPrefix,
  };

  const startedAtMs = Date.now();
  {
      let outcome;
      try {
        if (tool === 'tape' && target.market && target.tapeSafe === false) {
          // Refusing here is more useful than a run of identical failures:
          // the operation needs a fresh id each time and Tape cannot vary
          // its arguments.
          outcome = {
            ok: false,
            error: `${target.operation} cannot be benchmarked with Tape — `
              + 'it needs a unique id per call and Tape repeats one argument '
              + 'set for the whole run. Use Caliper for this target.',
          };
        } else {
          outcome = await runner(target, opts, job);
        }
      } catch (err) {
        outcome = { ok: false, error: err.message };
      }

      const m = outcome.metrics || {};
      job.results.push({
        id: target.id,
        channel: target.channel,
        contract: target.contract,
        fn: target.fn,
        repeat: rep,
        ok: !!outcome.ok,
        exitCode: outcome.exitCode ?? null,
        tps: Number.isFinite(m.tps) ? m.tps : 0,
        latencyAvg: Number.isFinite(m.latencyAvg) ? m.latencyAvg : 0,
        latencyMin: Number.isFinite(m.latencyMin) ? m.latencyMin : 0,
        latencyMax: Number.isFinite(m.latencyMax) ? m.latencyMax : 0,
        // null rather than 0 when the tool does not report latency, so the
        // UI can show "not reported" instead of an authoritative-looking zero
        latencyReported: Number.isFinite(m.latencyAvg),
        durationSec: Number.isFinite(m.durationSec) ? m.durationSec : null,
        blockCount: Number.isFinite(m.blockCount) ? m.blockCount : null,
        readTps: Number.isFinite(m.readTps) ? m.readTps : null,
        readLatencyAvg: Number.isFinite(m.readLatencyAvg) ? m.readLatencyAvg : null,
        avgBlockSize: Number.isFinite(m.avgBlockSize) ? m.avgBlockSize : null,
        successCount: Number.isFinite(m.successCount) ? m.successCount : 0,
        failedCount: Number.isFinite(m.failedCount) ? m.failedCount : 0,
        error: outcome.error || null,
        output: outcome.output || '',
        finishedAt: new Date().toISOString(),
        startedAtMs: startedAtMs,
        finishedAtMs: Date.now(),
      });

      job.summary = summarize(job.results, job);
  }
}

/* Running the whole job.
 *
 * Concurrency of 1 runs targets one after another, which measures what each
 * contract can do with the network to itself. That is a controlled figure,
 * برای مقایسه قراردادها خوب است، ولی شبیه بار واقعی یک شبکه سلامت نیست
 * like: there every channel carries traffic at once.
 *
 * Higher concurrency starts that many targets together. Fabric gives each
 * channel its own ledger and its own ordering, so channels are logically
 * independent — but they share these eight peers, one orderer, and one
 * host. Whether the isolation holds under simultaneous load is a question
 * only this mode can ask.
 *
 * Targets are grouped into waves. A wave finishes before the next starts,
 * so the aggregate figure below covers a period when exactly that many
 * targets were active.
 */
async function runJob(job) {
  const { options, targets, tool } = job;
  const runner = tool === 'caliper' ? runCaliperTarget : runTapeTarget;
  const width = Math.max(1, Math.min(32, options.concurrency || 1));

  for (let rep = 1; rep <= options.repeat; rep++) {
    for (let i = 0; i < targets.length; i += width) {
      if (job.cancelled) break;
      const wave = targets.slice(i, i + width);

      job.current = {
        id: wave.map((t) => t.id).join(', '),
        channel: wave.length === 1 ? wave[0].channel : `${wave.length} targets`,
        contract: wave.length === 1 ? wave[0].contract : 'concurrent wave',
        fn: wave.length === 1 ? wave[0].fn : '',
        repeat: rep,
        waveSize: wave.length,
        startedAt: new Date().toISOString(),
      };

      const waveStart = Date.now();
      await Promise.all(wave.map((t) => runOneTarget(job, t, rep, runner)));
      const waveMs = Date.now() - waveStart;

      // What the network carried while this wave was in flight. With one
      // target it equals that target's own rate; with several it is the
      // figure that says whether the network scaled or saturated.
      const waveResults = job.results.slice(-wave.length);
      const committed = waveResults.reduce((n, r) => n + (r.successCount || 0), 0);
      job.waves.push({
        repeat: rep,
        size: wave.length,
        targets: wave.map((t) => t.id),
        channels: [...new Set(wave.map((t) => t.channel))],
        durationSec: waveMs / 1000,
        committed,
        aggregateTps: waveMs > 0 ? (committed * 1000) / waveMs : 0,
        sumOfTargetTps: waveResults.reduce((n, r) => n + (r.tps || 0), 0),
      });
      job.summary = summarize(job.results, job);
    }
    if (job.cancelled) break;
  }

  job.current = null;
  job.summary = summarize(job.results, job);
  job.status = job.cancelled ? 'cancelled' : 'finished';
  job.finishedAt = new Date().toISOString();

  try {
    fs.writeFileSync(
      path.join(RUN_DIR, job.id, 'results.csv'), resultsToCsv(job), 'utf8');
    fs.writeFileSync(
      path.join(RUN_DIR, job.id, 'job.json'),
      JSON.stringify(publicJob(job), null, 2), 'utf8');
  } catch (_) {
    // Persisting the run is a convenience, not a requirement.
  }
}

function cancelJob(id) {
  const job = jobs.get(id);
  if (!job) return null;
  job.cancelled = true;
  for (const child of job._children) {
    try { child.kill('SIGKILL'); } catch (_) { /* already gone */ }
  }
  return job;
}

module.exports = {
  startJob,
  cancelJob,
  getJob: (id) => jobs.get(id) || null,
  listJobs: () => [...jobs.values()].map(publicJob).reverse(),
  publicJob,
  resultsToCsv,
  ensurePolicyFile,
  POLICY_FILES,
  POLICY_SOURCE,
  TEST_TOOLS_DIR,
  CALIPER_WORKSPACE,
  TAPE_CONFIG_DIR,
  RUN_DIR,
};
