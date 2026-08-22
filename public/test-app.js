/* ═══════════════════════════════════════════════════════════════════════
   test-app.js — benchmark controller.

   A run is a background job on the server: POST /api/bench/run returns an
   id, and this page polls /api/bench/job/:id until it finishes. That is
   what makes a twenty-channel sweep possible without the request timing
   out halfway through.

   Auth is handled by the browser against nginx basic auth; every request
   is same-origin, so credentials ride along automatically.
   ═══════════════════════════════════════════════════════════════════════ */

const API = window.location.origin + '/api';

const state = {
  catalog: null,
  mode: 'contract',
  tool: 'tape',
  pickedChannels: new Set(),
  pickedTargets: new Set(),
  jobId: null,
  poll: null,
  chart: null,
  matrixCells: new Map(),
  previewTimer: null,
};

/* ── Plumbing ─────────────────────────────────────────────────────── */

async function api(path, options = {}) {
  const res = await fetch(`${API}${path}`, { credentials: 'same-origin', ...options });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `${res.status} ${res.statusText}`);
  return body;
}

const post = (path, payload) =>
  api(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

const $ = (id) => document.getElementById(id);
const num = (id) => parseInt($(id).value, 10) || 0;

function showError(message) {
  const el = $('runError');
  if (!message) { el.hidden = true; return; }
  el.hidden = false;
  el.textContent = message;
}

/* ── Header ───────────────────────────────────────────────────────── */

async function loadHealth() {
  const dot = $('healthDot');
  const text = $('healthText');
  try {
    await api('/health');
    dot.className = 'dot online';
    text.textContent = 'Network online';
  } catch {
    dot.className = 'dot offline';
    text.textContent = 'Network unreachable';
  }
}

/* ── Catalog and pickers ──────────────────────────────────────────── */

async function loadCatalog() {
  const [cat, net] = await Promise.all([
    api('/bench/catalog'),
    api('/network/info').catch(() => ({ organizations: [] })),
  ]);
  state.catalog = cat;

  // Organizations, in both tool panes.
  for (const id of ['tapeOrg', 'calOrg']) {
    const sel = $(id);
    sel.innerHTML = '';
    (net.organizations || []).forEach((org) => {
      const o = document.createElement('option');
      o.value = org.orgNumber;
      o.textContent = `${org.name} — org${org.orgNumber}`;
      sel.appendChild(o);
    });
  }

  // Channel dropdowns.
  for (const id of ['oneChannel', 'chanOnly']) {
    const sel = $(id);
    sel.innerHTML = '';
    cat.channels.forEach((c) => {
      const o = document.createElement('option');
      o.value = c.channel;
      o.textContent = `${c.channel} — ${c.contracts.length} contracts`;
      if (c.channel === 'datachannel') o.selected = true;
      sel.appendChild(o);
    });
  }

  buildChannelPicker();
  buildTargetPicker();
  loadContracts();

  if (cat.drift && cat.drift.length) {
    showError(
      `The channel maps in bench-catalog.js and fabric.js disagree for: ${cat.drift.join(', ')}. ` +
      'Fix that before trusting any result — the two pages are describing different networks.');
  }
}

function loadContracts() {
  const channel = $('oneChannel').value;
  const entry = state.catalog.channels.find((c) => c.channel === channel);
  const sel = $('oneContract');
  sel.innerHTML = '';
  if (!entry) return;

  entry.contracts.forEach((t) => {
    const o = document.createElement('option');
    o.value = t.contract;
    o.textContent = t.contract + (t.writable ? '' : ' — read only')
      + (t.needsSeed ? ' — نیازمند بذرکاری مراکز' : '');
    o.dataset.writable = String(t.writable);
    o.dataset.needsSeed = String(t.needsSeed);
    o.dataset.fn = t.fn || '';
    sel.appendChild(o);
  });
  describeContract();
}

function describeContract() {
  const sel = $('oneContract');
  const opt = sel.selectedOptions[0];
  const hint = $('oneContractHint');
  if (!opt) { hint.textContent = '\u00a0'; return; }
  if (opt.dataset.writable !== 'true') {
    hint.textContent = 'No write function — turn on read-only contracts to include it';
  } else if (opt.dataset.needsSeed === 'true') {
    hint.textContent = 'پیش از نوشتن چیدمان مراکز را می‌خواند — بدون بذرکاری commit نمی‌شود';
  } else {
    hint.textContent = `Calls ${opt.dataset.fn}`;
  }
}

function buildChannelPicker() {
  const wrap = $('channelPicker');
  wrap.innerHTML = '';
  state.catalog.channels.forEach((c) => {
    const runnable = c.contracts.filter((t) => t.writable && !t.needsSeed).length;
    const el = document.createElement('button');
    el.className = 'pick';
    el.dataset.channel = c.channel;
    el.innerHTML =
      `<span class="p-name">${c.channel}</span>` +
      `<span class="p-meta">${runnable} runnable of ${c.contracts.length}</span>`;
    el.addEventListener('click', () => {
      if (state.pickedChannels.has(c.channel)) state.pickedChannels.delete(c.channel);
      else state.pickedChannels.add(c.channel);
      el.classList.toggle('is-on', state.pickedChannels.has(c.channel));
      schedulePreview();
    });
    wrap.appendChild(el);
  });
}

function buildTargetPicker() {
  const wrap = $('targetPicker');
  wrap.innerHTML = '';
  state.catalog.channels.forEach((c) => {
    c.contracts.forEach((t) => {
      const el = document.createElement('button');
      el.className = 'pick';
      el.dataset.id = t.id;
      el.dataset.search = `${c.channel} ${t.contract} ${t.fn || ''}`.toLowerCase();
      const flag = !t.writable ? ' · read only'
      : t.needsSeed ? ' · نیازمند بذر'
      : t.market && t.tapeSafe === false ? ' · Caliper only'
      : t.market && t.requires ? ' · has prerequisites'
      : '';
      el.innerHTML =
        `<span class="p-name">${t.contract}</span>` +
        `<span class="p-meta">${c.channel}${flag}</span>`;
      el.addEventListener('click', () => {
        if (state.pickedTargets.has(t.id)) state.pickedTargets.delete(t.id);
        else state.pickedTargets.add(t.id);
        el.classList.toggle('is-on', state.pickedTargets.has(t.id));
        schedulePreview();
      });
      wrap.appendChild(el);
    });
  });
}

function filterTargets() {
  const q = $('targetFilter').value.trim().toLowerCase();
  $('targetPicker').querySelectorAll('.pick').forEach((el) => {
    el.hidden = q ? !el.dataset.search.includes(q) : false;
  });
}

/* ── Selection → request body ─────────────────────────────────────── */

function selection() {
  const base = {
    mode: state.mode,
    includeSeedDep: $('includeSeedDep').checked,
    includeReadOnly: $('includeReadOnly').checked,
    includeMarket: $('includeMarket') ? $('includeMarket').checked : false,
    marketOnly: $('marketOnly') ? $('marketOnly').checked : false,
  };
  switch (state.mode) {
    case 'contract':
      return { ...base, channel: $('oneChannel').value, contract: $('oneContract').value };
    case 'channel':
      return { ...base, channel: $('chanOnly').value };
    case 'channels':
      return { ...base, channels: [...state.pickedChannels] };
    case 'targets':
      return {
        ...base,
        targets: [...state.pickedTargets].map((id) => {
          const [channel, contract] = id.split('/');
          return { channel, contract };
        }),
      };
    default:
      return base;
  }
}

function toolOptions() {
  if (state.tool === 'caliper') {
    return {
      tool: 'caliper',
      timeoutMs: num('calTimeout') * 1000,
      org: num('calOrg'),
      tps: num('calRate'),
      txNumber: num('calTx'),
      workers: num('calWorkers'),
      repeat: num('calRepeat'),
      concurrency: num('calConcurrency'),
      readPhase: $('calReadPhase').checked,
      readTps: num('calReadRate'),
      policy: 'any',
    };
  }
  const endorsers = num('tapeEndorsers');
  return {
    tool: 'tape',
    timeoutMs: num('tapeTimeout') * 1000,
    orgs: Array.from({ length: endorsers }, (_, i) => i + 1),
    org: num('tapeOrg'),
    tps: num('tapeRate'),
    txNumber: num('tapeTx'),
    burst: num('tapeBurst'),
    connections: num('tapeConns'),
    clientsPerConn: num('tapeClients'),
    repeat: num('tapeRepeat'),
    concurrency: num('tapeConcurrency'),
    policy: $('tapePolicy').value,
  };
}

function requestBody() {
  return { ...toolOptions(), selection: selection() };
}

/* ── Scope preview ────────────────────────────────────────────────── */

function schedulePreview() {
  clearTimeout(state.previewTimer);
  state.previewTimer = setTimeout(runPreview, 220);
}

function marketWarning(targets) {
  const el = $('scopeNote');
  if (!el) return;
  const caliperOnly = targets.filter((t) => t.tapeSafe === false);
  const needsPrep = targets.filter((t) => t.requires && t.tapeSafe !== false);
  const parts = [];
  if (state.tool === 'tape' && caliperOnly.length) {
    parts.push(`${caliperOnly.length} market target${caliperOnly.length > 1 ? 's need' : ' needs'} `
      + 'Caliper — Tape repeats one argument set and these need fresh state each call');
  }
  if (needsPrep.length) {
    parts.push('some market targets expect the contract\'s own write function to have run first');
  }
  el.textContent = parts.join('. ');
  el.hidden = parts.length === 0;
}

async function runPreview() {
  const set = (count, runs, time) => {
    $('scopeCount').textContent = count;
    $('scopeRuns').textContent = runs;
    $('scopeTime').textContent = time;
  };
  try {
    const p = await post('/bench/preview', requestBody());
    set(p.count, p.runs, formatDuration(p.estimatedSeconds));
    marketWarning(p.targets || []);
    $('scopeSummary').classList.toggle('is-empty', p.count === 0);
  } catch (err) {
    set('—', '—', '—');
    $('scopeSummary').classList.add('is-empty');
  }
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return '—';
  if (seconds < 90) return `${Math.round(seconds)}s`;
  const m = Math.round(seconds / 60);
  if (m < 90) return `${m}m`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

/* ── Running ──────────────────────────────────────────────────────── */

async function start() {
  showError('');
  const btn = $('runBtn');
  btn.disabled = true;

  try {
    const { id, total } = await post('/bench/run', requestBody());
    state.jobId = id;
    $('cancelBtn').hidden = false;
    $('runStatus').hidden = false;
    $('runStatusText').textContent = `Starting — ${total} targets queued`;
    $('results').hidden = false;
    $('csvLink').href = `${API}/bench/job/${id}/csv`;
    resetMatrix();
    if (state.chart) { state.chart.destroy(); state.chart = null; }
    poll();
    state.poll = setInterval(poll, 2000);
  } catch (err) {
    btn.disabled = false;
    showError(err.message);
  }
}

async function cancel() {
  if (!state.jobId) return;
  $('cancelBtn').disabled = true;
  try {
    await post(`/bench/job/${state.jobId}/cancel`, {});
    $('runStatusText').textContent = 'Stopping after the target in flight…';
  } catch (err) {
    showError(err.message);
    $('cancelBtn').disabled = false;
  }
}

async function poll() {
  if (!state.jobId) return;
  let job;
  try {
    job = await api(`/bench/job/${state.jobId}`);
  } catch (err) {
    stopPolling();
    showError(err.message);
    return;
  }

  render(job);

  if (job.status === 'running') {
    const at = job.current
      ? `${job.current.channel} · ${job.current.contract}`
      : 'preparing';
    // Elapsed time on the target in flight, so a stalled tool is visible
    // rather than looking like slow progress.
    let onTarget = '';
    if (job.current && job.current.startedAt) {
      const secs = Math.round((Date.now() - new Date(job.current.startedAt)) / 1000);
      onTarget = ` · ${formatDuration(secs)} on this target`;
      if (secs > 120) onTarget += ' — still waiting on the tool';
    }
    $('runStatusText').textContent =
      `${job.completed} of ${job.total * (job.options.repeat || 1)} — running ${at}${onTarget}`;
  } else {
    stopPolling();
    $('runStatus').hidden = true;
    $('cancelBtn').hidden = true;
    $('cancelBtn').disabled = false;
    $('runBtn').disabled = false;
    if (job.status === 'failed') showError(job.error || 'The run failed.');
  }
}

function stopPolling() {
  clearInterval(state.poll);
  state.poll = null;
  $('runBtn').disabled = false;
}

/* ── Rendering ────────────────────────────────────────────────────── */

function resetMatrix() {
  $('matrix').innerHTML = '';
  state.matrixCells.clear();
  $('resultRows').innerHTML = '';
  $('outputPanel').hidden = true;
}

function render(job) {
  const s = job.summary || {};
  const set = (id, v) => { $(id).firstChild.nodeValue = v; };
  set('mTps', (s.tpsMean || 0).toFixed(2));
  // With targets running together, the aggregate is what the network
  // carried; each target's own rate only tells half the story.
  const s2 = job.summary || {};
  const aggEl = $('mAggregate');
  if (aggEl) {
    const box = aggEl.closest('.readout');
    if (s2.concurrency > 1) {
      if (box) box.hidden = false;
      aggEl.firstChild.nodeValue = (s2.aggregateTpsMean || 0).toFixed(2);
      aggEl.title = `${s2.waveCount} waves of up to ${s2.concurrency} targets`;
    } else if (box) {
      box.hidden = true;
    }
  }

  const anyLatency = (job.results || []).some((r) => r.latencyReported);
  set('mLat', anyLatency ? (s.latencyMean || 0).toFixed(1) : 'n/r');
  $('mLat').title = anyLatency ? '' : 'Tape does not report latency — run Caliper for latency figures';
  set('mOk', String(s.committed || 0));
  set('mBad', String(s.rejected || 0));

  renderMatrix(job);
  renderRows(job);
  renderChart(job);
  $('resultCount').textContent =
    `${job.results.length} of ${job.total * (job.options.repeat || 1)} rows`;
}

function renderMatrix(job) {
  const matrix = $('matrix');

  const cellFor = (id) => {
    if (state.matrixCells.has(id)) return state.matrixCells.get(id);
    const [channel, contract] = id.split('/');
    const el = document.createElement('div');
    el.className = 'mcell';
    el.innerHTML =
      `<span class="c-contract">${contract}</span>` +
      `<span class="c-channel">${channel}</span>` +
      `<span class="c-tps">—</span>`;
    matrix.appendChild(el);
    state.matrixCells.set(id, el);
    return el;
  };

  // Latest pass wins, so a repeated sweep updates in place.
  for (const r of job.results) {
    const el = cellFor(r.id);
    el.className = `mcell ${r.ok && r.successCount > 0 ? 'is-ok' : 'is-bad'}`;
    el.querySelector('.c-tps').textContent =
      r.ok && Number.isFinite(r.tps) ? `${r.tps.toFixed(1)} tps` : 'failed';
    el.title = r.error || `${r.successCount} committed, ${r.failedCount} rejected`;
    el.onclick = () => showOutput(r);
  }

  if (job.current) {
    const el = cellFor(job.current.id);
    if (!el.classList.contains('is-ok') && !el.classList.contains('is-bad')) {
      el.className = 'mcell is-running';
      el.querySelector('.c-tps').textContent = 'running';
    }
  }
}

function renderRows(job) {
  const body = $('resultRows');
  body.innerHTML = '';
  job.results.forEach((r) => {
    const tr = document.createElement('tr');
    const ok = r.ok && r.successCount > 0;
    // Tape reports no latency, so show that rather than a zero that would
    // read as "instant". The dash is the honest answer.
    const lat = r.latencyReported
      ? `${r.latencyAvg.toFixed(1)}`
      : '<span class="dim" title="Tape does not report latency — use Caliper for that">n/r</span>';
    tr.innerHTML =
      `<td class="mono dim">${r.channel}</td>` +
      `<td class="strong">${r.contract}</td>` +
      `<td class="mono dim">${r.fn || '—'}</td>` +
      `<td class="mono dim">${r.repeat}</td>` +
      `<td class="num mono">${Number.isFinite(r.tps) ? r.tps.toFixed(2) : '—'}</td>` +
      `<td class="num mono">${r.durationSec ? r.durationSec.toFixed(2) : '—'}</td>` +
      `<td class="num mono dim">${r.blockCount ?? '—'}</td>` +
      `<td class="num mono dim">${r.avgBlockSize ? r.avgBlockSize.toFixed(0) : '—'}</td>` +
      `<td class="num mono">${lat}</td>` +
      `<td class="num mono ok">${r.successCount}</td>` +
      `<td class="num mono ${r.failedCount ? 'bad' : 'dim'}">${r.failedCount}</td>` +
      `<td><span class="badge ${ok ? 'ok' : 'fail'}">${ok ? 'committed' : 'failed'}</span></td>`;
    tr.style.cursor = 'pointer';
    tr.addEventListener('click', () => showOutput(r));
    body.appendChild(tr);
  });
}

function showOutput(r) {
  const panel = $('outputPanel');
  if (!r.output && !r.error) { panel.hidden = true; return; }
  panel.hidden = false;
  $('outputFor').textContent = `${r.channel} · ${r.contract}`;
  $('output').textContent = [r.error, r.output].filter(Boolean).join('\n\n');
  panel.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function renderChart(job) {
  const rows = job.results
    .filter((r) => Number.isFinite(r.tps) && r.tps > 0)
    .sort((a, b) => b.tps - a.tps)
    .slice(0, 40);

  if (!rows.length) return;

  const ink = getComputedStyle(document.body).getPropertyValue('--ink-faint').trim() || '#5C6C8C';
  const data = {
    labels: rows.map((r) => r.contract),
    datasets: [{
      label: 'Throughput (tps)',
      data: rows.map((r) => r.tps),
      backgroundColor: rows.map((r) => (r.successCount > 0 ? '#35D6C4' : '#F2596A')),
      borderRadius: 3,
      borderSkipped: false,
    }],
  };

  if (state.chart) {
    state.chart.data = data;
    state.chart.update('none');
    return;
  }

  state.chart = new Chart($('chart').getContext('2d'), {
    type: 'bar',
    data,
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            afterLabel: (ctx) => {
              const r = rows[ctx.dataIndex];
              return `${r.channel} · ${r.successCount} committed, ${r.failedCount} rejected`;
            },
          },
        },
      },
      scales: {
        y: { beginAtZero: true, grid: { color: 'rgba(255,255,255,0.06)' }, ticks: { color: ink } },
        x: { grid: { display: false }, ticks: { color: ink, maxRotation: 60, minRotation: 45, font: { size: 10 } } },
      },
    },
  });
}

/* ── Mode and tool switching ──────────────────────────────────────── */

function setMode(mode) {
  state.mode = mode;
  document.querySelectorAll('.scope-mode').forEach((b) =>
    b.classList.toggle('is-on', b.dataset.mode === mode));
  document.querySelectorAll('.scope-body').forEach((b) => {
    b.hidden = b.dataset.for !== mode;
  });
  schedulePreview();
}

function setTool(tool) {
  state.tool = tool;
  document.querySelectorAll('.tool-tab').forEach((b) => {
    const on = b.dataset.tool === tool;
    b.classList.toggle('is-on', on);
    b.setAttribute('aria-selected', String(on));
  });
  document.querySelectorAll('.tool-pane').forEach((p) => {
    p.hidden = p.dataset.tool !== tool;
  });
  schedulePreview();
}

function describePolicy() {
  const majority = $('tapePolicy').value === 'majority';
  $('tapePolicyHint').textContent = majority
    ? 'Not the deployed policy — label results as hypothetical'
    : 'The chaincode commits on one signature';
  // A five-of-eight policy cannot be met by fewer than five endorsers.
  const sel = $('tapeEndorsers');
  if (majority && Number(sel.value) < 5) sel.value = '5';
  [...sel.options].forEach((o) => { o.disabled = majority && Number(o.value) < 5; });
}

/* ── Boot ─────────────────────────────────────────────────────────── */

document.addEventListener('DOMContentLoaded', async () => {
  loadHealth();

  try {
    await loadCatalog();
  } catch (err) {
    showError(
      `Could not read the benchmark catalog — ${err.message}. ` +
      'If this says the endpoint is missing, run server/patch-index.sh to mount /api/bench.');
    return;
  }

  document.querySelectorAll('.scope-mode').forEach((b) =>
    b.addEventListener('click', () => setMode(b.dataset.mode)));
  document.querySelectorAll('.tool-tab').forEach((b) =>
    b.addEventListener('click', () => setTool(b.dataset.tool)));

  $('oneChannel').addEventListener('change', () => { loadContracts(); schedulePreview(); });
  $('oneContract').addEventListener('change', () => { describeContract(); schedulePreview(); });
  $('chanOnly').addEventListener('change', schedulePreview);
  $('includeSeedDep').addEventListener('change', schedulePreview);
  $('includeReadOnly').addEventListener('change', schedulePreview);
  ['includeMarket', 'marketOnly'].forEach((id) => {
    const el = $(id);
    if (!el) return;
    el.addEventListener('change', () => {
      // The two are mutually exclusive: "only" supersedes "include".
      if (id === 'marketOnly' && el.checked) $('includeMarket').checked = false;
      if (id === 'includeMarket' && el.checked) $('marketOnly').checked = false;
      schedulePreview();
    });
  });
  $('targetFilter').addEventListener('input', filterTargets);
  $('tapePolicy').addEventListener('change', () => { describePolicy(); schedulePreview(); });

  ['tapeRepeat', 'calRepeat', 'tapeTx', 'calTx', 'calRate', 'tapeRate']
    .forEach((id) => $(id).addEventListener('input', schedulePreview));

  document.querySelector('[data-pick="channels-all"]').addEventListener('click', () => {
    state.catalog.channels.forEach((c) => state.pickedChannels.add(c.channel));
    document.querySelectorAll('#channelPicker .pick').forEach((el) => el.classList.add('is-on'));
    schedulePreview();
  });
  document.querySelector('[data-pick="channels-none"]').addEventListener('click', () => {
    state.pickedChannels.clear();
    document.querySelectorAll('#channelPicker .pick').forEach((el) => el.classList.remove('is-on'));
    schedulePreview();
  });
  document.querySelector('[data-pick="targets-none"]').addEventListener('click', () => {
    state.pickedTargets.clear();
    document.querySelectorAll('#targetPicker .pick').forEach((el) => el.classList.remove('is-on'));
    schedulePreview();
  });

  $('runBtn').addEventListener('click', start);
  $('cancelBtn').addEventListener('click', cancel);

  describePolicy();
  schedulePreview();
});
