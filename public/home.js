/* Overview page — network health, last deployment summary, ambient map. */
const API = window.location.origin + '/api';

async function get(path) {
  const res = await fetch(`${API}${path}`, { credentials: 'same-origin' });
  if (!res.ok) throw new Error(`${res.status}`);
  return res.json();
}

async function loadHealth() {
  const dot = document.getElementById('healthDot');
  const text = document.getElementById('healthText');
  try {
    const h = await get('/health');
    dot.className = 'dot online';
    text.textContent = 'Network online';
    if (h.network) {
      document.getElementById('statOrgs').textContent = h.network.organizations ?? '—';
      document.getElementById('statChannels').textContent = h.network.channels ?? '—';
    }
  } catch (e) {
    dot.className = 'dot offline';
    text.textContent = 'Network unreachable';
  }
}

async function loadLast() {
  const stage = document.getElementById('heroStage');
  const empty = document.getElementById('heroEmpty');
  let data;
  try {
    data = await get('/scenario/last');
  } catch (e) {
    return;                       // nothing deployed yet — keep the empty state
  }
  empty.style.display = 'none';
  renderCoverage(stage, data, { compact: true });

  const t = data.topology || {};
  const p = data.performance || {};
  document.getElementById('sumFacility').textContent = (t.facilities || []).length;
  document.getElementById('sumIot').textContent = (t.iots || []).length;
  document.getElementById('sumUsers').textContent = (t.users || []).length;
  document.getElementById('sumOk').textContent =
    p.successCount != null ? `${p.successCount}/${p.totalTasks}` : '—';
  document.getElementById('sumTps').innerHTML =
    p.tps != null ? `${p.tps}<span class="u">tps</span>` : '—';
  document.getElementById('lastTag').textContent =
    data.savedAt ? new Date(data.savedAt).toLocaleString() : 'seed ' + data.seed;

  window.addEventListener('resize', () => renderCoverage(stage, data, { compact: true }));
}

document.addEventListener('DOMContentLoaded', () => { loadHealth(); loadLast(); });
