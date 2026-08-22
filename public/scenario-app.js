/* ═══════════════════════════════════════════════════════════════
   scenario-app.js — deployment simulation controller.

   Auth: none in JS. Nginx protects the whole origin with basic auth,
   so the browser holds the credentials after the first page load and
   attaches them to same-origin requests automatically.
   ═══════════════════════════════════════════════════════════════ */

const API = window.location.origin + '/api';

async function api(path, options = {}) {
  const res = await fetch(`${API}${path}`, { credentials: 'same-origin', ...options });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `${res.status} ${res.statusText}`);
  return body;
}

/* ── Topbar health ─────────────────────────────────────────── */
async function loadHealth() {
  const dot = document.getElementById('healthDot');
  const text = document.getElementById('healthText');
  if (!dot) return;
  try {
    await api('/health');
    dot.className = 'dot online';
    text.textContent = 'Network online';
  } catch {
    dot.className = 'dot offline';
    text.textContent = 'Network unreachable';
  }
}

/* ── Channel and contract picker ───────────────────────────── */
async function loadOptions() {
  const box = document.getElementById('channelList');
  try {
    const opts = await api('/scenario/options');
    box.innerHTML = '';
    for (const ch of opts.channels) {
      const row = document.createElement('div');
      row.className = 'chan';

      const head = document.createElement('label');
      head.className = 'chan-head';
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.className = 'chk';
      cb.dataset.channel = ch.channel;
      const name = document.createElement('span');
      name.className = 'chan-name';
      name.textContent = ch.channel;
      head.append(cb, name);

      const sel = document.createElement('select');
      sel.multiple = true;
      sel.size = 3;
      sel.dataset.channel = ch.channel;
      let writable = 0;
      for (const cc of ch.chaincodes) {
        const o = document.createElement('option');
        o.value = cc.name;
        o.textContent = cc.available ? `${cc.name} → ${cc.fn}` : `${cc.name} — no write path`;
        o.disabled = !cc.available;
        if (cc.available) writable++;
        if (cc.name === ch.defaultChaincode && cc.available) o.selected = true;
        sel.appendChild(o);
      }
      const count = document.createElement('span');
      count.className = 'chan-count';
      count.textContent = `${writable}/${ch.chaincodes.length}`;
      head.appendChild(count);

      row.append(head, sel);
      box.appendChild(row);
    }
  } catch (err) {
    box.innerHTML = `<p class="note warn">Channel list unavailable — ${err.message}</p>`;
  }
}

function collectSelection() {
  const out = [];
  document.querySelectorAll('.chk').forEach((c) => {
    if (!c.checked) return;
    const sel = document.querySelector(`select[data-channel="${c.dataset.channel}"]`);
    const ccs = [...sel.selectedOptions].filter((o) => !o.disabled).map((o) => o.value);
    if (ccs.length) out.push({ channel: c.dataset.channel, chaincodes: ccs });
  });
  return out;
}

/* ── Run ───────────────────────────────────────────────────── */
async function run() {
  const body = {
    iotCount: +document.getElementById('iotCount').value || 0,
    userCount: +document.getElementById('userCount').value || 0,
    seed: document.getElementById('seed').value,
    concurrency: +document.getElementById('concurrency').value || 6,
    connectEntities: document.getElementById('connectToggle').checked,
    selection: collectSelection(),
  };

  if (!body.selection.length && !body.connectEntities) {
    alert('Pick at least one channel, or leave device attachment switched on.');
    return;
  }

  const btn = document.getElementById('runBtn');
  const working = document.getElementById('working');
  btn.disabled = true;
  working.style.display = 'flex';

  try {
    const data = await api('/scenario/execute', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    render(data, false);
    document.getElementById('results').scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (err) {
    alert(`Simulation failed — ${err.message}`);
  } finally {
    btn.disabled = false;
    working.style.display = 'none';
  }
}

/* ── Last saved layout ─────────────────────────────────────── */
async function loadLast() {
  try {
    const data = await api('/scenario/last');
    render(data, true);
  } catch {
    /* nothing run yet — leave the results block hidden */
  }
}

/* ── Render ────────────────────────────────────────────────── */
function render(d, restored) {
  document.getElementById('results').style.display = 'block';

  const p = d.performance || {};
  const when = d.savedAt ? new Date(d.savedAt).toLocaleString('en-GB') : 'just now';
  const info = document.getElementById('runInfo');
  info.className = 'note info';
  info.textContent = restored
    ? `Showing the last deployment written on ${when}. Run again to place a new layout.`
    : `Deployment written on ${when}.`;

  if (p.totalTasks && p.successCount === 0) {
    info.className = 'note warn';
    info.textContent += ' Every transaction was rejected — see the failure sample below.';
  }

  const set = (id, v) => { const el = document.getElementById(id); if (el) el.firstChild.nodeValue = v; };
  set('rTps', p.tps ?? '—');
  set('rTotal', p.totalTasks ?? '—');
  set('rDur', p.durationMs != null ? (p.durationMs / 1000).toFixed(1) : '—');
  set('rSeed', d.seed ?? '—');
  document.getElementById('rOk').firstChild.nodeValue =
    p.successCount != null ? `${p.successCount}/${p.totalTasks}` : '—';
  set('rLat', p.latency ? p.latency.avg : '—');

  const lat = document.getElementById('rLat');
  if (p.latency && p.latency.max) lat.title = `min ${p.latency.min} ms · max ${p.latency.max} ms`;

  renderCatchment(document.getElementById('mapStage'), d);
  renderLegend(d);
  renderCells(d);
  renderWrites(p);
}

function renderLegend(d) {
  const ul = document.getElementById('legendOrgs');
  if (!ul) return;
  ul.innerHTML = (d.topology.facilities || []).map((a) => {
    const c = d.coverage?.[a.orgNum];
    const served = c ? c.iotCount + c.userCount : 0;
    return `<li><span class="swatch" style="background:${orgColor(a.orgNum)}"></span>
      org${a.orgNum} <span class="dim">${(a.x / 1000).toFixed(1)}, ${(a.y / 1000).toFixed(1)} km · ${served} served</span></li>`;
  }).join('');
}

function renderCells(d) {
  const t = document.getElementById('covTable');
  if (!t) return;
  const rows = Object.entries(d.coverage || {}).map(([org, c]) => {
    const total = c.iotCount + c.userCount;
    return `<tr>
      <td><span class="swatch" style="background:${orgColor(+org)}"></span> org${org}</td>
      <td class="mono">${c.facilityId}</td>
      <td class="mono num">${c.x}</td>
      <td class="mono num">${c.y}</td>
      <td class="num">${c.iotCount}</td>
      <td class="num">${c.userCount}</td>
      <td class="num strong">${total}</td>
    </tr>`;
  }).join('');
  t.innerHTML = `<thead><tr>
      <th>Organization</th><th>Macro TX</th><th>x (m)</th><th>y (m)</th>
      <th>Small cells</th><th>Users</th><th>Served</th>
    </tr></thead><tbody>${rows}</tbody>`;
}

const STAGE_NAMES = {
  facility: 'Macro transmitter records',
  connect: 'Device attachments',
  'entity-data': 'Device measurements',
};

function renderWrites(p) {
  const t = document.getElementById('chTable');
  if (!t) return;

  const line = (label, v, mono) => {
    const rate = v.total ? Math.round((v.ok / v.total) * 100) : 0;
    const bad = v.fail > 0;
    return `<tr>
      <td${mono ? ' class="mono"' : ''}>${label}</td>
      <td class="num">${v.total}</td>
      <td class="num ok">${v.ok}</td>
      <td class="num ${bad ? 'bad' : 'dim'}">${v.fail}</td>
      <td class="num">${rate}%</td>
    </tr>`;
  };

  const chans = Object.entries(p.perChannel || {}).map(([k, v]) => line(k, v, true)).join('');
  const kinds = Object.entries(p.perKind || {}).map(([k, v]) => line(STAGE_NAMES[k] || k, v)).join('');

  t.innerHTML = `<thead><tr><th>Channel</th><th>Sent</th><th>Committed</th><th>Rejected</th><th>Success</th></tr></thead>
    <tbody>${chans}</tbody>
    <thead><tr><th>Stage</th><th>Sent</th><th>Committed</th><th>Rejected</th><th>Success</th></tr></thead>
    <tbody>${kinds}</tbody>`;

  const box = document.getElementById('failBox');
  box.innerHTML = (p.failureSamples || []).length
    ? `<p class="note warn"><strong>Failure sample</strong><br>${
        p.failureSamples.map((f) => `<code>${f.chaincode}.${f.fn}</code> — ${f.error}`).join('<br>')
      }</p>`
    : '';
}

/* ── Boot ──────────────────────────────────────────────────── */
document.addEventListener('DOMContentLoaded', async () => {
  loadHealth();
  await loadOptions();
  await loadLast();
  document.getElementById('runBtn').addEventListener('click', run);
  document.getElementById('selAll').addEventListener('change', (e) => {
    document.querySelectorAll('.chk').forEach((c) => { c.checked = e.target.checked; });
  });
  let t;
  window.addEventListener('resize', () => {
    clearTimeout(t);
    t = setTimeout(() => {
      const stage = document.getElementById('mapStage');
      if (stage && stage.dataset.rendered) loadLast();
    }, 250);
  });
});
