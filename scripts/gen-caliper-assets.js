#!/usr/bin/env node
'use strict';

/* ═══════════════════════════════════════════════════════════════════════
   gen-caliper-assets.js — writes the Caliper workload and benchmark files.

   Two things are produced:

   1. Two generic workload modules (generic-write.js, generic-read.js).
      The expanded /api/bench runner writes a benchmark file per target at
      run time pointing at these, so all 90 targets are reachable without
      keeping dozens of near-identical files in sync.

   2. One named workload plus benchmark per distinct write function, at
      caliper/workloads/<Fn>.js and caliper/benchmarks/<Fn>.yaml. The
      original POST /api/test/execute route looks a workload up by the
      chaincode function name — install-test-tools.sh only ever wrote
      five files under different names, which is why that route could not
      find a workload for any channel.

   Usage:
     node scripts/gen-caliper-assets.js [--workspace DIR] [--force]
   ═══════════════════════════════════════════════════════════════════════ */

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const catalog = require(path.join(repoRoot, 'server', 'bench-catalog'));

const argv = process.argv.slice(2);
const force = argv.includes('--force');
const wsFlag = argv.indexOf('--workspace');
const WORKSPACE = wsFlag !== -1 && argv[wsFlag + 1]
  ? path.resolve(argv[wsFlag + 1])
  : path.resolve(repoRoot, 'test-tools', 'caliper-workspace');

const WORKLOAD_DIR = path.join(WORKSPACE, 'workload');
const BENCH_DIR = path.join(WORKSPACE, 'benchmarks');

let written = 0;
let skipped = 0;

function write(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (fs.existsSync(file) && !force) {
    const current = fs.readFileSync(file, 'utf8');
    if (current === content) { skipped++; return; }
  }
  fs.writeFileSync(file, content, 'utf8');
  written++;
}

/* ── Generic workloads ─────────────────────────────────────────────── */

// Every contract's write function and parameter order, embedded so the
// workload can still build correct arguments when the contract is
// overridden at run time and no explicit params are supplied.
const { GRID_SIZE_M, BENCH_SEED, MARKET_FN } = catalog;

const MARKET_TABLE = JSON.stringify(
  Object.fromEntries(
    Object.entries(MARKET_FN).map(([k, d]) => [k, { fn: d.fn, params: d.params }])
  ),
  null,
  2
);

const CONTRACT_TABLE = JSON.stringify(
  Object.fromEntries(
    Object.entries(catalog.CONTRACT_FN).map(([name, d]) => [name, { fn: d.fn, params: d.params }])
  ),
  null,
  2
);

const GENERIC_WRITE = `'use strict';

/* Generic write workload.
   Driven entirely by roundArguments, so one module covers every contract:

     contractId       chaincode name
     contractFunction write function to call
     params           parameter names, in order (from contract-fn-map.js)
     keyPrefix        prefix for the ledger key
     mspId            organization submitting the proposals

   Each worker owns its own slice of the key space, so no two workers
   write the same key and the run measures throughput rather than MVCC
   conflicts. */

/* Caliper's WorkloadModuleBase lives in @hyperledger/caliper-core. That
   package is not reliably resolvable from the workspace: caliper-cli keeps
   its own nested copy under its install directory, which Node will not
   search from here, and a separate global install may be missing entirely.
   Depending on where it happens to sit made every workload fail with
   "Cannot find module '@hyperledger/caliper-core'".

   So use it when it resolves, and fall back to an equivalent local base
   when it does not. Caliper calls only initializeWorkloadModule,
   submitTransaction and cleanupWorkloadModule, and does no instanceof
   check, so the fallback is behaviourally identical. */
let WorkloadModuleBase;
try {
  ({ WorkloadModuleBase } = require('@hyperledger/caliper-core'));
} catch (err) {
  WorkloadModuleBase = class {
    constructor() {
      this.workerIndex = 0;
      this.totalWorkers = 1;
      this.roundIndex = 0;
      this.roundArguments = {};
      this.sutAdapter = null;
      this.sutContext = null;
    }
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
      this.workerIndex = workerIndex;
      this.totalWorkers = totalWorkers;
      this.roundIndex = roundIndex;
      this.roundArguments = roundArguments;
      this.sutAdapter = sutAdapter;
      this.sutContext = sutContext;
    }
    async submitTransaction() {
      throw new Error('submitTransaction must be overridden');
    }
    async cleanupWorkloadModule() {}
  };
}

// Write function and parameter order for every contract on the network.
// Used when the benchmark file names a contract but not its parameters.
const CONTRACTS = ${CONTRACT_TABLE};

// Market operations. A round that names one of these calls it instead of
// the contract's own write function — the market is a second family of
// writes on the same contract, with its own argument shapes.
const MARKET = ${MARKET_TABLE};

const GRID = ${GRID_SIZE_M};

function marketValue(name, i, prefix) {
  switch (name) {
    // The same key the primary write function produces, so this entity has
    // already been admitted and holds a grant to sell.
    case 'fromAdmitted': return prefix + '-' + i;
    case 'accountID':
    case 'entityID':
    case 'from':
    case 'edgeEntity':   return prefix + '-a-' + i;
    case 'to':
    case 'relayEntity':  return prefix + '-b-' + i;
    case 'dealID':       return prefix + '-deal-' + i;
    case 'amount':       return '1000';
    case 'tier':         return String(1 + (i % 2));
    case 'hz':           return '20000';
    case 'priceMicro':   return '500';
    // نواحی از چیدمان بذر seed-1404 مراکز مشتق شده‌اند
    // corner furthest from every cell, the relay almost on top of one.
    // Seed-42 layout: the relay sits 565 m from the edge entity, close
    // enough for the device-to-device hop and far enough to reach a
    // different cell.
    case 'edgeX':        return String(3600 - 200 + (i * 79) % 400);
    case 'edgeY':        return String(8400 - 200 + (i * 113) % 400);
    case 'relayX':       return String(3600 - 200 + (i * 79) % 400 - 400);
    case 'relayY':       return String(8400 - 200 + (i * 113) % 400 - 400);
    default:             return 'v-' + i;
  }
}

const SHARED_REF = new Set(['facilityID']);
const ID_PARAMS = new Set([
  'id', 'subject', 'patientCommit', 'facilityID', 'unitID', 'claimID',
  'policyID', 'sessionID', 'channelID', 'resourceID',
]);

// Generated from server/bench-catalog.js — the values below are injected at
// generation time so the workload and the catalog cannot drift apart. They
// did once: the workload kept its own copy, never learned about the 'seed'
// parameter, and sent 'v-1' instead. Every transaction was then rejected with
// a seed mismatch — 500 failures out of 500, with nothing in the summary
// table to say why.
const GRID_SIZE_M = ${GRID_SIZE_M};
const BENCH_SEED = ${JSON.stringify(BENCH_SEED)};

function paramValue(name, i) {
  switch (name) {
    case 'seed':              return BENCH_SEED;
    case 'x':                 return String((i * 2654435761) % GRID_SIZE_M);
    case 'y':                 return String((i * 1597334677) % GRID_SIZE_M);
    case 'signal':            return String(-60 - (i % 40));
    case 'signalQuality':     return String(50 + (i % 50));
    case 'load':              return String(10 + (i % 90));
    case 'coverage':          return String(50 + (i % 50));
    case 'congestion':        return String(i % 100);
    case 'energy':            return String(100 + (i % 900));
    case 'latency':           return String(1 + (i % 50));
    case 'traffic':           return String(100 + (i % 2000));
    case 'interferenceLevel': return String(i % 30);
    case 'bandwidth':         return String(10 + (i % 90));
    case 'amount':            return String(1 + (i % 500));
    case 'value':             return String(1 + (i % 100));
    case 'powerLevel':        return String(1 + (i % 40));
    case 'priority':          return ['low', 'normal', 'high'][i % 3];
    case 'qosLevel':          return ['bronze', 'silver', 'gold'][i % 3];
    case 'status':            return 'Active';
    case 'healthStatus':      return 'Healthy';
    case 'complianceStatus':  return 'Compliant';
    case 'token':             return 'token-' + i;
    case 'role':              return ['reader', 'writer', 'admin'][i % 3];
    case 'policy':            return 'allow-all';
    case 'change':            return 'threshold-raised';
    case 'action':            return 'config-change';
    case 'activity':          return 'handover';
    case 'event':             return 'login-ok';
    case 'metric':            return 'latency';
    case 'resource':          return 'spectrum';
    case 'strategy':          return 'load-balance';
    case 'route':             return 'path-a';
    case 'config':            return 'band-n78';
    case 'faultType':         return 'link-down';
    case 'data':              return 'payload-' + i;
    case 'maxDistance':       return '5000';
    default:                  return 'v-' + i;
  }
}

class GenericWrite extends WorkloadModuleBase {
  async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
    await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
    const a = this.roundArguments || {};
    this.contractId = a.contractId;
    this.mspId = a.mspId || 'org1MSP';
    this.prefix = (a.keyPrefix || 'bench') + '-w' + workerIndex;
    this.i = 0;

    if (!this.contractId) {
      throw new Error('generic-write needs contractId in roundArguments');
    }

    // The contract table wins over any inherited defaults, so overriding
    // the contract cannot leave the argument list shaped for a different
    // one. Explicit roundArguments still take priority over both.
    // contractId is Caliper's unique alias (channel-qualified); the
    // argument shape is keyed by the plain contract name.
    // A market operation replaces both the function and the argument shape.
    this.market = a.marketOperation && MARKET[a.marketOperation]
      ? MARKET[a.marketOperation]
      : null;
    if (this.market) {
      this.fn = this.market.fn;
      this.params = this.market.params;
    } else {
      const known = CONTRACTS[a.contractName || this.contractId];
      this.fn = known ? known.fn : a.contractFunction;
      this.params = known ? known.params : a.params;
    }

    if (!this.fn) {
      throw new Error('No write function known for contract ' + this.contractId);
    }
    if (!Array.isArray(this.params) || !this.params.length) {
      throw new Error('No parameter list known for contract ' + this.contractId);
    }
  }

  buildArgs(i) {
    if (this.market) {
      return this.params.map((p) => marketValue(p, i, this.prefix));
    }
    let keyTaken = false;
    return this.params.map((p) => {
      if (!keyTaken && ID_PARAMS.has(p)) { keyTaken = true; return this.prefix + '-' + i; }
      if (SHARED_REF.has(p)) return 'facility-1';
      if (ID_PARAMS.has(p)) return p + '-' + this.prefix + '-' + i;
      return paramValue(p, i);
    });
  }

  async submitTransaction() {
    this.i++;
    await this.sutAdapter.sendRequests({
      contractId: this.contractId,
      contractFunction: this.fn,
      invokerMspId: this.mspId,
      contractArguments: this.buildArgs(this.i),
      readOnly: false,
    });
  }
}

module.exports.createWorkloadModule = () => new GenericWrite();
`;

const GENERIC_READ = `'use strict';

/* Generic read workload.
   Reads back keys written by generic-write in an earlier round, so the
   run measures query latency rather than not-found errors.

     contractId       chaincode name
     contractFunction read function (QueryAsset)
     keyPrefix        the prefix the write round used
     keySpace         how many keys that round wrote per worker
     mspId            organization submitting the proposals */

/* Caliper's WorkloadModuleBase lives in @hyperledger/caliper-core. That
   package is not reliably resolvable from the workspace: caliper-cli keeps
   its own nested copy under its install directory, which Node will not
   search from here, and a separate global install may be missing entirely.
   Depending on where it happens to sit made every workload fail with
   "Cannot find module '@hyperledger/caliper-core'".

   So use it when it resolves, and fall back to an equivalent local base
   when it does not. Caliper calls only initializeWorkloadModule,
   submitTransaction and cleanupWorkloadModule, and does no instanceof
   check, so the fallback is behaviourally identical. */
let WorkloadModuleBase;
try {
  ({ WorkloadModuleBase } = require('@hyperledger/caliper-core'));
} catch (err) {
  WorkloadModuleBase = class {
    constructor() {
      this.workerIndex = 0;
      this.totalWorkers = 1;
      this.roundIndex = 0;
      this.roundArguments = {};
      this.sutAdapter = null;
      this.sutContext = null;
    }
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
      this.workerIndex = workerIndex;
      this.totalWorkers = totalWorkers;
      this.roundIndex = roundIndex;
      this.roundArguments = roundArguments;
      this.sutAdapter = sutAdapter;
      this.sutContext = sutContext;
    }
    async submitTransaction() {
      throw new Error('submitTransaction must be overridden');
    }
    async cleanupWorkloadModule() {}
  };
}

class GenericRead extends WorkloadModuleBase {
  async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
    await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
    const a = this.roundArguments || {};
    this.contractId = a.contractId;
    this.fn = a.contractFunction || 'QueryAsset';
    this.mspId = a.mspId || 'org1MSP';
    this.prefix = (a.keyPrefix || 'bench') + '-w' + workerIndex;
    this.keySpace = Math.max(1, Number(a.keySpace) || 100);

    if (!this.contractId) {
      throw new Error('generic-read needs contractId in roundArguments');
    }
  }

  async submitTransaction() {
    const i = 1 + Math.floor(Math.random() * this.keySpace);
    await this.sutAdapter.sendRequests({
      contractId: this.contractId,
      contractFunction: this.fn,
      invokerMspId: this.mspId,
      contractArguments: [this.prefix + '-' + i],
      readOnly: true,
    });
  }
}

module.exports.createWorkloadModule = () => new GenericRead();
`;

write(path.join(WORKLOAD_DIR, 'generic-write.js'), GENERIC_WRITE);
write(path.join(WORKLOAD_DIR, 'generic-read.js'), GENERIC_READ);

/* ── Named per-function assets for the original route ──────────────── */

// Which contract each write function belongs to. A function name such as
// 'Log' is shared by many contracts; pick the first channel that offers
// it so the named asset has a concrete default, and let the environment
// override it at run time.
const fnHome = new Map();
for (const t of catalog.allTargets()) {
  if (!t.writable || !t.fn) continue;
  if (!fnHome.has(t.fn)) fnHome.set(t.fn, t);
}

const namedWorkload = (t) => `'use strict';

/* ${t.fn} — named workload for POST /api/test/execute.
   Generated by scripts/gen-caliper-assets.js. Do not edit by hand.

   Defaults to ${t.contract} on ${t.channel}. The server passes
   CALIPER_CHAINCODE and CALIPER_CHANNEL when a run targets a different
   contract that exposes the same function, and those win. */

const base = require('./generic-write.js');

module.exports.createWorkloadModule = () => {
  const mod = base.createWorkloadModule();
  const original = mod.initializeWorkloadModule.bind(mod);
  mod.initializeWorkloadModule = async function (wi, tw, ri, args, adapter, ctx) {
    const merged = Object.assign({
      contractId: process.env.CALIPER_CONTRACT_ID || ${JSON.stringify(t.caliperId)},
      contractName: process.env.CALIPER_CHAINCODE || ${JSON.stringify(t.contract)},
      contractFunction: ${JSON.stringify(t.fn)},
      params: ${JSON.stringify(t.params)},
      keyPrefix: 'ui',
    }, args || {});
    return original(wi, tw, ri, merged, adapter, ctx);
  };
  return mod;
};
`;

const namedBenchmark = (t) => `# ${t.fn} — generated by scripts/gen-caliper-assets.js. Do not edit by hand.
# Target rate and duration come from the UI as CALIPER_TPS / CALIPER_DURATION;
# Caliper reads rateControl statically, so the values below are the defaults
# used when the run is started from the command line.
test:
  name: ${t.fn}
  description: ${t.fn} on ${t.contract} (${t.channel})
  workers:
    number: 2
  rounds:
    - label: ${t.fn}
      txNumber: 500
      rateControl:
        type: fixed-rate
        opts:
          tps: 20
      workload:
        module: caliper/workloads/${t.fn}.js
        arguments:
          contractId: ${t.caliperId}
          contractName: ${t.contract}
          keyPrefix: ui
monitors:
  resource:
    - module: docker
      options:
        interval: 5
        containers:
          - peer0.org1.example.com
          - orderer.example.com
`;

for (const [fn, t] of fnHome) {
  // Named workloads sit beside the generic ones. The server resolves them
  // as test-tools/caliper/workloads/<Fn>.js, which reaches this directory
  // through the two symlinks ensured below.
  write(path.join(WORKLOAD_DIR, `${fn}.js`), namedWorkload(t));
  write(path.join(BENCH_DIR, `${fn}.yaml`), namedBenchmark(t));
}

/* ── Path aliases the server expects ───────────────────────────────────
   POST /api/test/execute looks for test-tools/caliper/workloads/<Fn>.js.
   install-test-tools.sh normally creates these, but the generator can be
   run on its own, so make sure they exist either way.                  */

function ensureSymlink(linkPath, target) {
  try {
    if (fs.existsSync(linkPath) || fs.lstatSync(linkPath).isSymbolicLink()) return;
  } catch (_) { /* not there yet */ }
  try {
    fs.mkdirSync(path.dirname(linkPath), { recursive: true });
    fs.symlinkSync(target, linkPath);
  } catch (err) {
    console.warn(`  Could not link ${linkPath} → ${target}: ${err.message}`);
  }
}

ensureSymlink(path.join(WORKSPACE, 'workloads'), 'workload');
ensureSymlink(path.resolve(WORKSPACE, '..', 'caliper'), path.basename(WORKSPACE));

/* ── Endorsement policy files ──────────────────────────────────────── */

const TAPE_DIR = path.resolve(WORKSPACE, '..', 'tape-configs');
write(path.join(TAPE_DIR, 'endorsement-any.rego'), `package tape

default allow = false

# Mirrors the deployed chaincode policy:
#   OR('org1MSP.member', ... ,'org8MSP.member')
# A single endorsement satisfies it.
allow {
    count(input) >= 1
}
`);
write(path.join(TAPE_DIR, 'endorsement-majority.rego'), `package tape

default allow = false

# Hypothetical stricter policy: MAJORITY of 8 organizations.
# This is NOT what is deployed on the network. Use it only for the
# deliberate policy-cost comparison, and label the results as such.
allow {
    count(input) >= 5
}
`);

const counts = catalog.catalog().counts;
console.log(`Caliper assets written to ${WORKSPACE}`);
console.log(`  generic workloads:  2`);
console.log(`  named workloads:    ${fnHome.size} (one per write function)`);
console.log(`  named benchmarks:   ${fnHome.size}`);
console.log(`  policy files:       2 (${TAPE_DIR})`);
console.log(`  files written:      ${written}, already current: ${skipped}`);
console.log(
  `  network: ${counts.channels} channels, ${counts.targets} targets, ` +
  `${counts.writable} writable, ${counts.antennaDep} به چیدمان بذرکاری‌شده مراکز نیاز دارند`);

const drift = catalog.assertCatalogInSync();
if (drift.length) {
  console.warn(`\n  Warning: channel maps disagree for: ${drift.join(', ')}`);
  console.warn('  bench-catalog.js and fabric.js must list the same contracts.');
}
