#!/usr/bin/env node
'use strict';
/* Structural check for the generated Go. No compiler is available here, so
   this verifies what a compiler would catch first: balanced delimiters,
   every called helper defined, every import used, no non-deterministic
   calls, and no duplicate declarations. */

const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');

// Pull each contract's Go out of the heredocs.
const files = [];
for (const m of src.matchAll(/^\s{8}(\w+)\)\n\s+cat > chaincode\/\$contract\/chaincode\.go <<'CHAINCODE_EOF'\n([\s\S]*?)\nCHAINCODE_EOF/gm)) {
  files.push({ name: m[1], go: m[2] });
}

// The shared half lives in a second file written once per contract. Go
// compiles both as one package, so a check that only saw chaincode.go
// would report every shared helper as missing.
const sharedMatch = src.match(/cat > chaincode\/\$contract\/shared\.go <<'SHARED_EOF'\n([\s\S]*?)\nSHARED_EOF/);
const shared = sharedMatch ? sharedMatch[1] : '';
if (!shared) console.log('  ! no shared.go template found');
files.push({ name: 'shared.go', go: shared, isShared: true });

let fail = 0;
const bad = (name, msg) => { fail++; console.log(`  ✗ ${name}: ${msg}`); };

// Strip strings, runes and comments so delimiters inside them do not count.
function strip(go) {
  let out = '', i = 0;
  while (i < go.length) {
    const c = go[i];
    if (c === '/' && go[i + 1] === '/') { while (i < go.length && go[i] !== '\n') i++; continue; }
    if (c === '/' && go[i + 1] === '*') { i += 2; while (i < go.length && !(go[i] === '*' && go[i + 1] === '/')) i++; i += 2; continue; }
    if (c === '`') { i++; while (i < go.length && go[i] !== '`') i++; i++; out += '""'; continue; }
    if (c === '"') { i++; while (i < go.length && !(go[i] === '"' && go[i - 1] !== '\\')) i++; i++; out += '""'; continue; }
    if (c === "'") { i++; while (i < go.length && !(go[i] === "'" && go[i - 1] !== '\\')) i++; i++; out += "''"; continue; }
    out += c; i++;
  }
  return out;
}

const REQUIRED = [
  'SeedFacilityLayout', 'SetConfig', 'getConfig', 'loadFacilities', 'commit',
  'evaluate', 'txTime', 'submitter', 'readAccount', 'writeAccount', 'NetworkStatus',
  'QueryAsset', 'QueryAllAssets', 'ValidateCoverage', 'Init',
  'SetResources', 'SetAssociation', 'SetTier', 'SetEconomy', 'RankCells',
  'LoadBalance', 'BalanceOf', 'Transfer', 'accountOf',
];
const KERNEL = [
  'Isqrt', 'Log2Milli', 'Log10Milli', 'exp2FracQ16', 'exp2Q16', 'LinearQ16',
  'DbmFromLinearQ16', 'fnv1a', 'mix32', 'hashUniform', 'ShadowingMilliDb',
  'PlaceOnGrid', 'DistanceM', 'PathLossMilliDb', 'NoiseFloorMilliDbm',
  'RssiMilliDbm', 'SinrMilliDb', 'ShannonBps', 'floorDiv',
  'MicroWattFromMilliDbm', 'TransmitTimeMicroS', 'TransmitEnergyMicroJ',
  'fairShareHz', 'loadDeviation', 'transactionCost',
  'parseCoord', 'parseIntOr', 'txTimestamp',
];

console.log(`contracts found: ${files.length}\n`);

for (const { name, go, isShared } of files) {
  // Methods and helpers may live in either file; check against both.
  const both = isShared ? go : go + '\n' + shared;
  const s = strip(go);

  for (const [open, close, label] of [['{', '}', 'braces'], ['(', ')', 'parens'], ['[', ']', 'brackets']]) {
    const a = (s.match(new RegExp('\\' + open, 'g')) || []).length;
    const b = (s.match(new RegExp('\\' + close, 'g')) || []).length;
    if (a !== b) bad(name, `${label} unbalanced: ${a} vs ${b}`);
  }

  const defined = new Set();
  for (const m of go.matchAll(/^func (?:\([^)]*\) )?(\w+)\(/gm)) defined.add(m[1]);

  if (!isShared) {
    // Shared methods hang off NetworkBase, which the contract embeds.
    for (const fn of REQUIRED) {
      const own = new RegExp(`func \\(s \\*${name}\\) ${fn}\\(`).test(go);
      const inherited = new RegExp(`func \\(s \\*NetworkBase\\) ${fn}\\(`).test(shared);
      if (!own && !inherited) bad(name, `method ${fn} missing from both files`);
    }
    if (!/NetworkBase/.test(go)) bad(name, 'does not embed NetworkBase');
  }
  const definedBoth = new Set();
  for (const m of both.matchAll(/^func (?:\([^)]*\) )?(\w+)\(/gm)) definedBoth.add(m[1]);
  for (const fn of KERNEL) {
    if (!definedBoth.has(fn)) bad(name, `helper ${fn} missing`);
  }

  // Duplicate top-level declarations would fail to compile.
  // Duplicates across the two files break the build just as surely as
  // duplicates within one — that is exactly how BalanceOf ended up
  // declared twice.
  const seen = new Set();
  for (const m of both.matchAll(/^func (\w+)\(/gm)) {
    if (seen.has(m[1])) bad(name, `duplicate func ${m[1]}`);
    seen.add(m[1]);
  }
  const methods = new Set();
  for (const m of both.matchAll(/^func \((?:\w+ )?\*(\w+)\) (\w+)\(/gm)) {
    const key = `${m[1]}.${m[2]}`;
    if (methods.has(key)) bad(name, `duplicate method ${key}`);
    methods.add(key);
  }
  const types = new Set();
  for (const m of both.matchAll(/^type (\w+) /gm)) {
    if (types.has(m[1])) bad(name, `duplicate type ${m[1]}`);
    types.add(m[1]);
  }
  const consts = new Set();
  for (const m of both.matchAll(/^\s{4}(\w+)\s+=\s/gm)) {
    if (consts.has(m[1])) bad(name, `duplicate constant ${m[1]}`);
    consts.add(m[1]);
  }

  // Imports must match usage exactly — Go rejects both unused and missing.
  const imports = (go.match(/import \(([\s\S]*?)\)/) || ['', ''])[1];
  for (const pkg of ['json', 'fmt', 'strconv', 'time']) {
    const declared = imports.includes(`"${pkg}"`) || imports.includes(`/${pkg}"`);
    const used = new RegExp(`\\b${pkg}\\.`).test(s);
    if (declared && !used) bad(name, `import ${pkg} unused`);
    if (!declared && used) bad(name, `import ${pkg} missing`);
  }
  if (/\bmath\./.test(s)) bad(name, 'math package used — not bit-reproducible across platforms');
  if (/\brand\./.test(s)) bad(name, 'rand used — forbidden in chaincode');
  if (/time\.Now/.test(s)) bad(name, 'time.Now used — forbidden in chaincode');
  if (/float(32|64)/.test(s)) bad(name, 'floating point used in the model');

  // Every struct field a method reads must exist on that struct. Release
  // reaches into the record type for ServingCell, which only the
  // قراردادهای selector دارند؛ ledger و guarded آن را ندارند.
  for (const m of go.matchAll(/var (\w+) (\w+)\n([\s\S]{0,900}?)\n}/g)) {
    const [, varName, typeName, body] = m;
    const tb = (go.match(new RegExp(`type ${typeName} struct \\{([\\s\\S]*?)\\n\\}`)) || [])[1];
    if (!tb) continue;
    const tf = new Set([...tb.matchAll(/^\s+(\w+)\s+\w/gm)].map((x) => x[1]));
    for (const u of body.matchAll(new RegExp(`\\b${varName}\\.(\\w+)`, 'g'))) {
      if (!tf.has(u[1])) bad(name, `${typeName} has no field ${u[1]} (used as ${varName}.${u[1]})`);
    }
  }

  // A string literal directly adjacent to an identifier is a syntax error
  // in Go, and it is exactly what mangled escaping produces: a nested \"
  // inside a JavaScript template literal collapses to a bare " and turns
  //     "must be \\"nearest\\" or ..."
  // into
  //     "must be "nearest" or ..."
  // which still has an even number of quotes, so counting them proves
  // nothing. Walking the line and checking what follows each closing quote
  // does catch it.
  go.split('\n').forEach((line, i) => {
    const text = line.replace(/\/\/.*$/, '');
    let k = 0;
    while (k < text.length) {
      if (text[k] === '`') {            // raw string — skip to its end
        k++;
        while (k < text.length && text[k] !== '`') k++;
        k++;
        continue;
      }
      if (text[k] !== '"') { k++; continue; }
      k++;                              // opening quote
      while (k < text.length) {
        if (text[k] === '\\') { k += 2; continue; }
        if (text[k] === '"') break;
        k++;
      }
      k++;                              // closing quote
      const next = text[k];
      if (next && /[A-Za-z0-9_]/.test(next)) {
        bad(name, `line ${i + 1}: a string literal is glued to \`${next}\` — escaping is mangled: ${text.trim().slice(0, 72)}`);
        break;
      }
    }
  });

  // A named type used but never declared. Go catches this immediately;
  // the structural check did not, which is how GenericRecord — a name
  // passed to the shared template but never defined — reached the
  // compiler.
  const declaredTypes = new Set([...both.matchAll(/^type (\w+) /gm)].map((m) => m[1]));
  const builtin = new Set(['Facility', 'Account', 'NetConfig', 'Record', 'Selection', 'News2Result', 'ClaimResult',
    'EnergyBudget', 'WorkTask', 'RelayDeal', 'SpectrumGrant', 'TokenAccount',
    'GenericRecord', 'NetworkBase']);
  for (const m of both.matchAll(/\bvar \w+ ([A-Z]\w+)\b/g)) {
    if (!declaredTypes.has(m[1]) && !builtin.has(m[1])) {
      bad(name, `type ${m[1]} is used but never declared`);
    }
  }
  for (const t of builtin) {
    if (new RegExp(`\\bvar \\w+ ${t}\\b`).test(both) && !declaredTypes.has(t)) {
      bad(name, `type ${t} is used but never declared`);
    }
  }

  // An identifier that looks like a package-level constant but is never
  // declared. Go rejects this at once; the structural check did not, which
  // is how defaultQosPrice — referenced from the network block but declared
  // nowhere — reached the compiler.
  const declaredConsts = new Set();
  for (const m of both.matchAll(/^\s{4}(\w+)\s+=\s/gm)) declaredConsts.add(m[1]);
  for (const m of both.matchAll(/^\s*(?:const|var)\s+(\w+)\s/gm)) declaredConsts.add(m[1]);
  const referenced = new Set();
  // Only the default* family: max* collides with parameter names such as
  // maxCapacity, which are locals rather than package constants.
  for (const m of both.matchAll(/\bdefault[A-Z]\w+\b/g)) referenced.add(m[0]);
  for (const id of referenced) {
    if (!declaredConsts.has(id)) bad(name, `constant ${id} is used but never declared`);
  }

  // A helper called but never declared. The constant check below caught
  // defaultQosPrice; this catches the same mistake for functions, which is
  // how effectiveHz — used in the admission check but declared nowhere —
  // reached the compiler and took all twenty channels down with it.
  const declaredFns = new Set();
  for (const m of both.matchAll(/^func (?:\([^)]*\) )?(\w+)\(/gm)) declaredFns.add(m[1]);
  const goBuiltins = new Set([
    'append', 'cap', 'close', 'complex', 'copy', 'delete', 'imag', 'len',
    'make', 'new', 'panic', 'print', 'println', 'real', 'recover',
    'int64', 'int', 'int32', 'uint', 'uint32', 'uint64', 'string', 'byte',
    'bool', 'rune', 'error', 'float64', 'float32',
    'if', 'for', 'switch', 'return', 'func', 'range', 'defer', 'go', 'select',
    'var', 'const', 'type', 'else', 'case', 'default', 'break', 'continue',
  ]);
  // Bare calls only: anything with a receiver or package qualifier is out
  // of scope for this check.
  // Comments carry mathematical notation — log2(x), log10(d) — that looks
  // like a call and is not one, so they come out first.
  const code = both
    .split('\n')
    .map((l) => l.replace(/\/\/.*$/, ''))
    .join('\n');
  for (const m of code.matchAll(/(?:^|[^.\w"])([a-z]\w*)\(/gm)) {
    const fn = m[1];
    if (goBuiltins.has(fn) || declaredFns.has(fn)) continue;
    bad(name, `helper ${fn}() is called but never declared`);
    break;
  }

  if (!isShared && !/func main\(\)/.test(go)) bad(name, 'no main');
  if (!isShared && !new RegExp(`NewChaincode\\(new\\(${name}\\)\\)`).test(go)) bad(name, 'main does not register this contract');

  // Every struct field assigned in the record literal must exist on the
  // record type — which is not the first struct in the file, that is the
  // contract receiver.
  const lit = go.match(/record := (\w+)\{([\s\S]*?)\n    \}/);
  if (lit) {
    const recType = lit[1];
    const recBody = (go.match(new RegExp(`type ${recType} struct \\{([\\s\\S]*?)\\n\\}`)) || ['', ''])[1];
    const fields = new Set([...recBody.matchAll(/^\s+(\w+)\s+\w/gm)].map((m) => m[1]));
    if (!fields.size) bad(name, `record type ${recType} not found or empty`);
    for (const m of lit[2].matchAll(/^\s+(\w+):/gm)) {
      if (!fields.has(m[1])) bad(name, `record literal sets unknown field ${m[1]}`);
    }
    // And every non-optional field should be set.
    for (const f of fields) {
      if (!new RegExp(`^\\s+${f}:`, 'm').test(lit[2])) bad(name, `field ${f} never assigned`);
    }
  } else if (!isShared) {
    bad(name, 'no record literal found');
  }
}

console.log(fail ? `\n✗ ${fail} problems` : '\n✅ all structural checks passed');
process.exit(fail ? 1 : 0);
