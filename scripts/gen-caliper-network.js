#!/usr/bin/env node
'use strict';

/* ═══════════════════════════════════════════════════════════════════════
   gen-caliper-network.js — writes Caliper's network configuration.

   Replaces the network-config.yaml and connection profiles that
   install-test-tools.sh generated in bash. Three things were wrong there,
   and the third is the one that limits the expanded benchmark:

   1. connectionProfile.path was './connection-profile-orgN.json', which
      Caliper resolves against the WORKSPACE ROOT — but the file is written
      into networks/. Every run died with "No connection profile file
      found". Paths here are absolute, so they hold no matter which
      directory is passed as the workspace.

   2. Every contract was declared as 'javascript' when the chaincode is Go,
      and pointed at ../chaincode/<name>, a path that does not exist. With
      create:false Caliper never builds them, so this was mislabelling
      rather than breakage — but it made the file misleading to read.

   3. Only ONE contract per channel was declared — the designated test
      contract from channel_contract_map.sh. Caliper cannot invoke a
      contract it has not been told about, so 70 of the 90 benchmark
      targets were unreachable no matter what the UI asked for. Every
      contract on every channel is declared here.

   Crypto material and endpoints come from server/config.js, the same
   source the dashboard and the Tape runner use, so all three agree.

   Usage:
     node scripts/gen-caliper-network.js [--workspace DIR]
   ═══════════════════════════════════════════════════════════════════════ */

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const catalog = require(path.join(repoRoot, 'server', 'bench-catalog'));
const config = require(path.join(repoRoot, 'server', 'config'));

const argv = process.argv.slice(2);
const wsFlag = argv.indexOf('--workspace');
const WORKSPACE = wsFlag !== -1 && argv[wsFlag + 1]
  ? path.resolve(argv[wsFlag + 1])
  : path.resolve(repoRoot, 'test-tools', 'caliper-workspace');

const NETWORKS_DIR = path.join(WORKSPACE, 'networks');
fs.mkdirSync(NETWORKS_DIR, { recursive: true });

/* وضعیت TLS از config/.env خوانده می‌شود، نه از config.tlsEnabled.
 *
 * config.js مقدارش را از CORE_PEER_TLS_ENABLED می‌گیرد، و آن متغیر فقط در
 * محیط سرویس داشبورد ست است. وقتی این اسکریپت را دستی از خط فرمان اجرا
 * کنید نیست — و پروفایل با grpc:// و بدون tlsCACerts ساخته می‌شود، در
 * حالی که شبکه TLS دارد. نتیجه: هر تراکنش Caliper رد می‌شود بی‌آنکه
 * خطای گواهی دیده شود، فقط «۰ موفق از ۵۰۰».
 *
 * .env همان منبعی است که docker-compose هم از آن می‌خواند، پس همان‌جا
 * پرسیده می‌شود. متغیر محیطی همچنان بازنویسی می‌کند. */
function tlsEnabledFromEnvFile() {
  if (process.env.CORE_PEER_TLS_ENABLED !== undefined) {
    return process.env.CORE_PEER_TLS_ENABLED === 'true';
  }
  try {
    const envPath = path.join(repoRoot, 'config', '.env');
    const m = fs.readFileSync(envPath, 'utf8')
      .match(/^NETWORK_TLS\s*=\s*(\S+)/m);
    if (m) return m[1].trim() === 'true';
  } catch (_) {
    /* .env نیست — به config برمی‌گردیم */
  }
  return !!config.tlsEnabled;
}

const tlsOn = tlsEnabledFromEnvFile();
const scheme = tlsOn ? 'grpcs' : 'grpc';
const channels = Object.keys(catalog.CHANNEL_CHAINCODE_MAP);
const ORGS = [1, 2, 3, 4, 5, 6, 7, 8];

/* ── Locate an organization's admin key and certificate ─────────────── */

function firstFileIn(dir) {
  try {
    const files = fs.readdirSync(dir).filter((f) => !f.startsWith('.')).sort();
    return files.length ? path.join(dir, files[0]) : null;
  } catch (_) {
    return null;
  }
}

const identities = new Map();
const missing = [];

for (const n of ORGS) {
  const org = config.getOrg(n);
  if (!org) { missing.push(`org${n}: not in the server config`); continue; }

  const key = firstFileIn(org.adminKeyDir);
  const cert = firstFileIn(org.adminCertDir);
  if (!key || !cert) {
    missing.push(`org${n}: ${!key ? `no key in ${org.adminKeyDir}` : `no cert in ${org.adminCertDir}`}`);
    continue;
  }
  identities.set(n, {
    org,
    key,
    cert,
    name: path.basename(path.dirname(path.dirname(org.adminCertDir))),
  });
}

if (!identities.size) {
  console.error('No usable crypto material found for any organization.');
  missing.forEach((m) => console.error(`  ${m}`));
  console.error('\nCheck CRYPTO_BASE, or run scripts/network.sh to regenerate.');
  process.exit(1);
}

/* ── Connection profile, one per organization ───────────────────────── */

function connectionProfile(n) {
  const { org } = identities.get(n);
  const peerName = `peer0.org${n}.example.com`;

  const chan = {};
  for (const c of channels) {
    chan[c] = {
      orderers: ['orderer.example.com'],
      peers: {
        [peerName]: {
          endorsingPeer: true,
          chaincodeQuery: true,
          ledgerQuery: true,
          eventSource: true,
        },
      },
    };
  }

  const peer = { url: `${scheme}://${org.peerEndpoint}` };
  const orderer = { url: `${scheme}://${config.orderer.endpoint}` };
  if (tlsOn) {
    peer.tlsCACerts = { path: org.tlsRootCert };
    peer.grpcOptions = { 'ssl-target-name-override': peerName };
    orderer.tlsCACerts = { path: config.orderer.tlsCaCert };
    orderer.grpcOptions = { 'ssl-target-name-override': 'orderer.example.com' };
  }

  return {
    name: `health-network-org${n}`,
    version: '1.0.0',
    client: {
      organization: org.mspId,
      connection: { timeout: { peer: { endorser: '300' }, orderer: '300' } },
    },
    channels: chan,
    organizations: {
      [org.mspId]: { mspid: org.mspId, peers: [peerName] },
    },
    orderers: { 'orderer.example.com': orderer },
    peers: { [peerName]: peer },
  };
}

/* ── Network config ─────────────────────────────────────────────────── */

function networkConfig() {
  const lines = [
    '# Generated by scripts/gen-caliper-network.js — do not edit by hand.',
    '# Every contract on every channel is declared, so any benchmark target',
    '# the UI offers can actually be invoked. Connection profile paths are',
    '# absolute: Caliper resolves relative ones against the workspace root,',
    '# which is not where the profiles live.',
    'name: 6G-Network-Multi-Org',
    'version: "2.0.0"',
    'caliper:',
    '  blockchain: fabric',
    '',
    'channels:',
  ];

  let contractCount = 0;
  for (const [channel, contracts] of Object.entries(catalog.CHANNEL_CHAINCODE_MAP)) {
    lines.push(`  - channelName: ${channel}`);
    lines.push('    create: false');
    lines.push('    contracts:');
    for (const c of contracts) {
      // Chaincode is already committed on the channel, so only the id and
      // version matter — Caliper uses them to address it, not to build it.
      lines.push(`      - id: ${c}`);
      // contractID must be unique across the whole file, not per channel.
      // Four contracts sit on two channels each, so the plain name would
      // collide and Caliper would reject the configuration outright.
      lines.push(`        contractID: ${catalog.caliperId(channel, c)}`);
      lines.push('        version: v1');
      lines.push('        language: golang');
      contractCount++;
    }
  }

  lines.push('', 'organizations:');
  for (const [n, id] of identities) {
    lines.push(`  - mspid: ${id.org.mspId}`);
    lines.push('    identities:');
    lines.push('      certificates:');
    lines.push(`        - name: '${id.name}'`);
    lines.push('          clientPrivateKey:');
    lines.push(`            path: '${id.key}'`);
    lines.push('          clientSignedCert:');
    lines.push(`            path: '${id.cert}'`);
    lines.push('    connectionProfile:');
    lines.push(`      path: '${path.join(NETWORKS_DIR, `connection-profile-org${n}.json`)}'`);
    lines.push('      discover: false');
  }

  return { text: lines.join('\n') + '\n', contractCount };
}

/* ── Write ──────────────────────────────────────────────────────────── */

for (const n of identities.keys()) {
  fs.writeFileSync(
    path.join(NETWORKS_DIR, `connection-profile-org${n}.json`),
    JSON.stringify(connectionProfile(n), null, 2),
    'utf8'
  );
}

const { text, contractCount } = networkConfig();
fs.writeFileSync(path.join(NETWORKS_DIR, 'network-config.yaml'), text, 'utf8');

// The server addresses a run as networks/orgN.yaml; all of them describe
// the same network, differing only in which identity submits.
for (const n of ORGS) {
  const link = path.join(NETWORKS_DIR, `org${n}.yaml`);
  try { fs.unlinkSync(link); } catch (_) { /* not there */ }
  try {
    fs.symlinkSync('network-config.yaml', link);
  } catch (err) {
    fs.copyFileSync(path.join(NETWORKS_DIR, 'network-config.yaml'), link);
  }
}

console.log(`Caliper network configuration written to ${NETWORKS_DIR}`);
console.log(`  connection profiles: ${identities.size} (absolute paths)`);
console.log(`  channels declared:   ${channels.length}`);
console.log(`  contracts declared:  ${contractCount}`);
console.log(`  TLS:                 ${tlsOn ? 'on' : 'off'} (${scheme})`);

if (missing.length) {
  console.warn('\nOrganizations skipped:');
  missing.forEach((m) => console.warn(`  ${m}`));
}

// A profile that names a peer the host cannot resolve fails at connect
// time with a message that does not mention DNS, so check it here.
try {
  const hosts = fs.readFileSync('/etc/hosts', 'utf8');
  const unresolved = ORGS
    .filter((n) => identities.has(n))
    .map((n) => `peer0.org${n}.example.com`)
    .filter((h) => !hosts.includes(h));
  if (unresolved.length) {
    console.warn(`\nNot in /etc/hosts: ${unresolved.join(', ')}`);
    console.warn('  Caliper runs on the host and resolves these by name.');
    console.warn('  Add them: for i in 1 2 3 4 5 6 7 8; do');
    console.warn('    echo "127.0.0.1 peer0.org$i.example.com" >> /etc/hosts; done');
  }
} catch (_) { /* not readable — skip the check */ }
