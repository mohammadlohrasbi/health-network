/* ═══════════════════════════════════════════════════════════════
   explorer-app.js — block explorer.
   Reads the ledger through /api/explorer, which serves everything
   from the qscc system chaincode. No auth handling here: nginx has
   already authenticated the browser for this origin.
   ═══════════════════════════════════════════════════════════════ */

const API = window.location.origin + '/api';

let channel = null;
let oldestLoaded = null;
let rows = [];

async function api(path) {
  const res = await fetch(`${API}${path}`, { credentials: 'same-origin' });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `${res.status} ${res.statusText}`);
  return body;
}

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const shortHash = (h) => (h ? `${h.slice(0, 10)}…${h.slice(-6)}` : '—');
const when = (t) => (t ? new Date(t).toLocaleString('en-GB') : '—');

/* ── Topbar ────────────────────────────────────────────────── */
async function loadHealth() {
  const dot = document.getElementById('healthDot');
  const text = document.getElementById('healthText');
  try {
    await api('/health');
    dot.className = 'dot online';
    text.textContent = 'Network online';
  } catch {
    dot.className = 'dot offline';
    text.textContent = 'Network unreachable';
  }
}

/* ── Channel tiles ─────────────────────────────────────────── */
async function loadChannels() {
  const grid = document.getElementById('channelGrid');
  try {
    const data = await api('/explorer/summary');
    const live = data.channels.filter((c) => c.deployed);
    const idle = data.channels.filter((c) => !c.deployed);

    grid.innerHTML = live.map((c) => `
      <button class="chan-tile" data-channel="${esc(c.channel)}">
        <span class="t-name">${esc(c.channel)}</span>
        <span class="t-h">${c.height}<em>blocks</em></span>
      </button>`).join('')
      + idle.map((c) => `
      <div class="chan-tile idle" title="${esc(c.reason || 'not deployed')}">
        <span class="t-name">${esc(c.channel)}</span>
        <span class="t-h dim">unavailable</span>
        <span class="t-why">${esc((c.reason || 'not deployed').slice(0, 90))}</span>
      </div>`).join('');

    grid.querySelectorAll('.chan-tile[data-channel]').forEach((b) =>
      b.addEventListener('click', () => selectChannel(b.dataset.channel)));

    if (live.length) {
      selectChannel(live[0].channel);
    } else {
      const why = (idle[0] && idle[0].reason) || 'no reason reported';
      grid.insertAdjacentHTML('afterend',
        `<p class="note warn"><strong>No chain could be read.</strong> The peer reported:<br>
         <code>${esc(why)}</code><br><br>
         If this says the channel does not exist, deploy it with
         <code>deploy-staged.sh channel &lt;name&gt;</code>. Any other message points at the
         explorer's read path rather than the ledger.</p>`);
    }
  } catch (err) {
    grid.innerHTML = `<p class="note warn">Chain heights unavailable — ${esc(err.message)}</p>`;
  }
}

function markActive() {
  document.querySelectorAll('.chan-tile[data-channel]').forEach((b) =>
    b.classList.toggle('on', b.dataset.channel === channel));
}

/* ── Select a channel ──────────────────────────────────────── */
async function selectChannel(name) {
  channel = name;
  oldestLoaded = null;
  rows = [];
  markActive();
  document.getElementById('chainView').style.display = 'block';
  document.getElementById('cChannel').textContent = name;
  document.getElementById('detailPanel').style.display = 'none';
  document.getElementById('searchOut').innerHTML = '';
  await loadBlocks(true);
}

/* ── Block list ────────────────────────────────────────────── */
async function loadBlocks(reset) {
  const table = document.getElementById('blockTable');
  if (reset) table.innerHTML = '<tbody><tr><td class="dim">Loading blocks…</td></tr></tbody>';

  try {
    const q = reset ? '' : `&before=${oldestLoaded}`;
    const data = await api(`/explorer/blocks?channel=${encodeURIComponent(channel)}&limit=12${q}`);

    if (reset) {
      document.getElementById('cHeight').firstChild.nodeValue = data.height;
      document.getElementById('cHash').textContent = data.currentBlockHash || '—';
      rows = [];
    }
    rows = rows.concat(data.blocks);
    oldestLoaded = data.oldest;

    const committed = rows.reduce((s, b) => s + (b.committedCount || 0), 0);
    const sent = rows.reduce((s, b) => s + (b.txCount || 0), 0);
    document.getElementById('cCommitted').firstChild.nodeValue = committed;
    document.getElementById('cRejected').firstChild.nodeValue = sent - committed;

    table.innerHTML = `<thead><tr>
        <th>Block</th><th>Time</th><th>Txs</th><th>Rejected</th>
        <th>Contracts</th><th>Signed by</th><th>Data hash</th>
      </tr></thead><tbody>${rows.map((b) => {
        const bad = (b.txCount || 0) - (b.committedCount || 0);
        return `<tr class="rowlink" data-n="${b.number}">
          <td class="mono strong">#${b.number}</td>
          <td class="dim">${when(b.timestamp)}</td>
          <td class="num">${b.txCount ?? '—'}</td>
          <td class="num ${bad ? 'bad' : 'dim'}">${bad}</td>
          <td class="mono" style="font-size:11px">${esc((b.chaincodes || []).join(', ')) || '—'}</td>
          <td class="mono" style="font-size:11px">${esc((b.submitters || []).join(', ')) || '—'}</td>
          <td class="mono dim" style="font-size:11px">${shortHash(b.dataHash)}</td>
        </tr>`;
      }).join('')}</tbody>`;

    table.querySelectorAll('.rowlink').forEach((tr) =>
      tr.addEventListener('click', () => openBlock(+tr.dataset.n)));

    document.getElementById('rangeInfo').textContent =
      `Showing blocks ${oldestLoaded}–${rows[0].number} of ${data.height}`;
    document.getElementById('moreBtn').style.display = oldestLoaded > 0 ? '' : 'none';
  } catch (err) {
    table.innerHTML = `<tbody><tr><td><span class="note warn">${esc(err.message)}</span></td></tr></tbody>`;
  }
}

/* ── Block detail ──────────────────────────────────────────── */
async function openBlock(number) {
  const panel = document.getElementById('detailPanel');
  const body = document.getElementById('detailBody');
  panel.style.display = 'block';
  document.getElementById('detailTag').textContent = `#${number}`;
  body.innerHTML = '<div class="working"><span class="spinner"></span> Reading block…</div>';
  panel.scrollIntoView({ behavior: 'smooth', block: 'start' });

  try {
    const b = await api(`/explorer/block?channel=${encodeURIComponent(channel)}&number=${number}`);
    body.innerHTML = `
      <div class="kv">
        <div><span>Block</span><b class="mono">#${b.number}</b></div>
        <div><span>Time</span><b>${when(b.timestamp)}</b></div>
        <div><span>Transactions</span><b>${b.txCount}</b></div>
        <div><span>Committed</span><b class="ok">${b.committedCount}</b></div>
        <div style="grid-column:1/-1"><span>Data hash</span><b class="mono" style="word-break:break-all;font-size:11.5px">${esc(b.dataHash)}</b></div>
      </div>
      ${b.transactions.map(txCard).join('')}`;
  } catch (err) {
    body.innerHTML = `<p class="note warn">${esc(err.message)}</p>`;
  }
}

function txCard(t) {
  const args = (t.args || []).map((a) => `<code>${esc(a)}</code>`).join(' ');
  return `<div class="txcard ${t.valid ? '' : 'bad'}">
    <div class="tx-top">
      <span class="badge ${t.valid ? 'ok' : 'fail'}">${esc(t.validation || (t.valid ? 'VALID' : 'INVALID'))}</span>
      <span class="mono tx-id">${esc(t.txId || '—')}</span>
    </div>
    <div class="kv small">
      <div><span>Submitted by</span><b>${esc(t.submitter || '—')}</b></div>
      <div><span>Contract</span><b class="mono">${esc(t.chaincode || '—')}</b></div>
      <div><span>Function</span><b class="mono">${esc(t.function || '—')}</b></div>
      <div><span>Type</span><b>${esc(t.type || '—')}</b></div>
      ${t.endorsements != null ? `<div><span>Endorsements</span><b>${t.endorsements}</b></div>` : ''}
      ${t.timestamp ? `<div><span>Time</span><b>${when(t.timestamp)}</b></div>` : ''}
    </div>
    ${args ? `<div class="tx-args"><span>Arguments</span> ${args}</div>` : ''}
    ${t.error ? `<p class="note warn" style="margin:10px 0 0">${esc(t.error)}</p>` : ''}
  </div>`;
}

/* ── Search ────────────────────────────────────────────────── */
async function findTx() {
  const id = document.getElementById('txId').value.trim();
  const out = document.getElementById('searchOut');
  if (!id) return;
  out.innerHTML = '<div class="working"><span class="spinner"></span> Searching…</div>';
  try {
    const t = await api(`/explorer/tx?channel=${encodeURIComponent(channel)}&id=${encodeURIComponent(id)}`);
    out.innerHTML = `<p class="note info">Found in block #${t.blockNumber}.</p>${txCard(t)}`;
  } catch (err) {
    out.innerHTML = `<p class="note warn">${esc(err.message)}</p>`;
  }
}

/* ── Boot ──────────────────────────────────────────────────── */
document.addEventListener('DOMContentLoaded', async () => {
  loadHealth();
  await loadChannels();
  document.getElementById('moreBtn').addEventListener('click', () => loadBlocks(false));
  document.getElementById('goBlock').addEventListener('click', () => {
    const n = Number(document.getElementById('blockNum').value);
    if (Number.isFinite(n) && n >= 0) openBlock(n);
  });
  document.getElementById('goTx').addEventListener('click', findTx);
  document.getElementById('txId').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') findTx();
  });
});
