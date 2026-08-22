// ============================================================
//  6G Fabric Network Dashboard — app.js
//  Network Topology from network.sh (L426–434, L459–476):
//    - 8 orgs (org1–org8), 1 orderer
//    - 20 channels (all orgs participate → full-mesh)
//  Channel→Contract mapping from channel_contract_map.sh (L14–44)
// ============================================================

// ---- 1) Network Topology Data ----
const ORDERER = {
  id: "orderer.example.com",
  label: "Orderer",
  group: "orderer",
  port: 7050
};

const ORGS = Array.from({ length: 8 }, (_, k) => {
  const i = k + 1;
  return {
    id: `peer0.org${i}.example.com`,
    label: `Org${i}`,
    group: "org",
    mspId: `org${i}MSP`,
    port: 7051 + k * 1000  // 7051, 8051, ..., 14051
  };
});

// Channel→Contracts map (source: channel_contract_map.sh L14–44)
const CHANNEL_CONTRACTS = {
  "patientchannel": [
    "RegisterPatient",
    "UpdateDemographics",
    "LinkNationalIndex",
    "MergeDuplicateRecord",
    "DeactivatePatient",
    "QueryPatientSummary"
  ],
  "clinicalchannel": [
    "RecordDiagnosis",
    "AppendProgressNote",
    "RecordVitalSigns",
    "RecordAllergy",
    "RecordProcedure",
    "RecordDischargeSummary",
    "CreateMedicalRecord"
  ],
  "admissionchannel": [
    "RequestAdmission",
    "TriagePatient",
    "AssignPriority",
    "AdmitPatient",
    "TransferWard",
    "DischargePatient",
    "RecordEdArrival"
  ],
  "bedchannel": [
    "AllocateBed",
    "ReleaseBed",
    "ReserveIcuBed",
    "ReportBedCensus",
    "RequestBedCapacity"
  ],
  "surgerychannel": [
    "ScheduleSurgery",
    "ReserveOrSlot",
    "CancelSurgery",
    "RecordSurgicalOutcome",
    "RequestEmergencyOr"
  ],
  "equipmentchannel": [
    "RegisterDevice",
    "ReserveDevice",
    "ReleaseDevice",
    "ReportDeviceFault",
    "LogDeviceMaintenance"
  ],
  "pharmacychannel": [
    "PrescribeDrug",
    "DispenseDrug",
    "VerifyDrugSafety",
    "RegisterDrugBatch",
    "RecallDrugBatch",
    "ReturnDrug",
    "CheckDrugInteraction"
  ],
  "bloodchannel": [
    "RegisterBloodUnit",
    "RequestBloodUnit",
    "IssueBloodUnit",
    "CrossMatchScreen",
    "ReturnBloodUnit",
    "ReportBloodInventory"
  ],
  "labchannel": [
    "OrderLabTest",
    "RecordLabResult",
    "RequestLabCapacity",
    "FlagCriticalResult"
  ],
  "imagingchannel": [
    "OrderImaging",
    "RecordImagingReport",
    "RequestImagingSlot"
  ],
  "staffchannel": [
    "RegisterStaff",
    "AssignShift",
    "RequestOnCall",
    "RecordCredential",
    "RevokeCredential"
  ],
  "referralchannel": [
    "CreateReferral",
    "AcceptReferral",
    "RejectReferral",
    "TransferPatient",
    "RequestSpecialistOpinion",
    "CloseReferral"
  ],
  "emergencychannel": [
    "DispatchAmbulance",
    "AssignAmbulanceDestination",
    "ReportMassCasualty",
    "ActivateCrisisProtocol",
    "ReleaseAmbulance",
    "RequestPrehospitalDestination"
  ],
  "insurancechannel": [
    "VerifyEligibility",
    "SubmitClaim",
    "AdjudicateClaim",
    "SettleClaim",
    "RejectClaim",
    "RecordCoveragePolicy"
  ],
  "supplychannel": [
    "RegisterSupplyItem",
    "RecordShipment",
    "ReceiveShipment",
    "ReportStockLevel",
    "RequestRestock"
  ],
  "marketchannel": [
    "MintResourceToken",
    "TransferToken",
    "BalanceOf",
    "ShareBedCapacity",
    "TradeOrSlot",
    "LendStaffHours"
  ],
  "consentchannel": [
    "GrantConsent",
    "RevokeConsent",
    "CheckConsent",
    "ShareDataWithProvider",
    "LogDataAccess",
    "EmergencyOverrideAccess"
  ],
  "auditchannel": [
    "LogPatientAudit",
    "LogClinicalAudit",
    "LogAccessAudit",
    "LogDrugAudit",
    "LogBloodAudit",
    "LogFinancialAudit",
    "LogSystemAudit"
  ],
  "compliancechannel": [
    "RecordAccreditation",
    "ReportIncident",
    "RecordQualityIndicator",
    "VerifyProtocolAdherence"
  ],
  "analyticschannel": [
    "ReportOccupancy",
    "ReportWaitTime",
    "ReportOutcomeIndicator",
    "ReportEpidemicSignal"
  ]
};

const CHANNELS = Object.keys(CHANNEL_CONTRACTS);

// Full-mesh: all 8 orgs participate in all 20 channels (network.sh L426–434)
const CHANNEL_ORGS = Object.fromEntries(
  CHANNELS.map(ch => [ch, ORGS.map(o => o.id)])
);

// ---- 2) Build Network Graph ----
function buildNetworkGraph() {
  const nodes = [];
  const edges = [];
  const seenContract = new Set();

  // Orderer node
  nodes.push(ORDERER);

  // Org nodes + org→orderer edges
  ORGS.forEach(org => {
    nodes.push(org);
    edges.push({ from: org.id, to: ORDERER.id, group: "org-orderer" });
  });

  // Channel nodes + org→channel + channel→contract edges
  CHANNELS.forEach(ch => {
    nodes.push({ id: ch, label: ch, group: "channel" });

    // Org membership
    (CHANNEL_ORGS[ch] || []).forEach(orgId => {
      edges.push({ from: orgId, to: ch, group: "org-channel" });
    });

    // Contracts
    (CHANNEL_CONTRACTS[ch] || []).forEach(c => {
      if (!seenContract.has(c)) {
        nodes.push({ id: c, label: c, group: "contract" });
        seenContract.add(c);
      }
      edges.push({ from: ch, to: c, group: "channel-contract" });
    });
  });

  return { nodes, edges };
}

// ---- 3) Render Network Map (vis-network) ----
function renderNetworkMap(containerId = "network-map") {
  const { nodes, edges } = buildNetworkGraph();

  const data = {
    nodes: new vis.DataSet(nodes),
    edges: new vis.DataSet(edges)
  };

  const options = {
    groups: {
      orderer:  { color: { background: "#c0392b", border: "#922b21" }, shape: "diamond", size: 30 },
      org:      { color: { background: "#2980b9", border: "#1f618d" }, shape: "box", size: 20 },
      channel:  { color: { background: "#27ae60", border: "#1e8449" }, shape: "ellipse", size: 16 },
      contract: { color: { background: "#f39c12", border: "#d68910" }, shape: "dot", size: 10 }
    },
    physics: {
      stabilization: { iterations: 200 },
      barnesHut: { gravitationalConstant: -12000, springLength: 150 }
    },
    edges: {
      smooth: { type: "continuous" },
      arrows: { to: { enabled: true, scaleFactor: 0.5 } },
      color: { inherit: "from", opacity: 0.4 }
    },
    interaction: { hover: true, tooltipDelay: 100 },
    layout: { improvedLayout: true }
  };

  const container = document.getElementById(containerId);
  if (!container) {
    console.warn(`Container #${containerId} not found. Network map not rendered.`);
    return null;
  }

  const network = new vis.Network(container, data, options);

  // Optional: click handler for node info
  network.on("click", (params) => {
    if (params.nodes.length > 0) {
      const nodeId = params.nodes[0];
      const node = data.nodes.get(nodeId);
      console.log("Node clicked:", node);
    }
  });

  return network;
}

// ---- 4) Dashboard State & UI Logic ----
let currentOrg = null;
let currentChannel = null;
let networkInfo = null;
let editingAssetId = null;

// DOM elements
const orgSelect = document.getElementById('orgSelect');
const channelSelect = document.getElementById('channelSelect');
const loadBtn = document.getElementById('loadBtn');
const createBtn = document.getElementById('createBtn');
const assetsBody = document.getElementById('assetsBody');
const logOutput = document.getElementById('logOutput');
const modalOverlay = document.getElementById('modalOverlay');
const assetForm = document.getElementById('assetForm');
const modalTitle = document.getElementById('modalTitle');
const cancelBtn = document.getElementById('cancelBtn');
const healthDot = document.getElementById('healthDot');
const healthText = document.getElementById('healthText');
const orgCount = document.getElementById('orgCount');
const channelCount = document.getElementById('channelCount');
const ordererInfo = document.getElementById('ordererInfo');

// Transfer & History modals
const transferModal = document.getElementById('transferModal');
const historyModal = document.getElementById('historyModal');
const transferForm = document.getElementById('transferForm');
const cancelTransferBtn = document.getElementById('cancelTransferBtn');
const closeHistoryBtn = document.getElementById('closeHistoryBtn');
const historyContent = document.getElementById('historyContent');
let transferringAssetId = null;

// ---- 5) Initialize ----
document.addEventListener('DOMContentLoaded', () => {
  checkHealth();
  loadNetworkInfo();
  
  // Render network map if container exists
  if (document.getElementById('network-map')) {
    renderNetworkMap();
    log('Network map rendered', 'info');
  }
  
  loadBtn.addEventListener('click', loadAssets);
  createBtn.addEventListener('click', openCreateModal);
  cancelBtn.addEventListener('click', closeModal);
  assetForm.addEventListener('submit', saveAsset);
  
  // Transfer & History event listeners
  if (transferForm) transferForm.addEventListener('submit', saveTransfer);
  if (cancelTransferBtn) cancelTransferBtn.addEventListener('click', closeTransferModal);
  if (closeHistoryBtn) closeHistoryBtn.addEventListener('click', closeHistoryModal);
  
  setInterval(checkHealth, 30000); // Health check every 30s
});

// ---- 6) Health Check ----
async function checkHealth() {
  try {
    const res = await fetch('/api/health');
    const data = await res.json();
    
    if (data.status === 'ok') {
      healthDot.className = 'dot online';
      healthText.textContent = 'Online';
    } else {
      healthDot.className = 'dot offline';
      healthText.textContent = 'Degraded';
    }
  } catch (err) {
    healthDot.className = 'dot offline';
    healthText.textContent = 'Offline';
    log(`Health check failed: ${err.message}`, 'error');
  }
}

// ---- 7) Load Network Info ----
async function loadNetworkInfo() {
  try {
    const res = await fetch('/api/network/info');
    networkInfo = await res.json();
    
    // Populate org selector
    orgSelect.innerHTML = '<option value="">-- Select Org --</option>';
    networkInfo.organizations.forEach(org => {
      const opt = document.createElement('option');
      opt.value = org.orgNumber;
      opt.textContent = `${org.name} (${org.mspId})`;
      orgSelect.appendChild(opt);
    });
    
    // Populate channel selector
    channelSelect.innerHTML = '<option value="">-- Select Channel --</option>';
    networkInfo.channels.forEach(ch => {
      const opt = document.createElement('option');
      opt.value = ch;
      opt.textContent = ch;
      channelSelect.appendChild(opt);
    });
    
    // Update summary
    orgCount.textContent = networkInfo.organizations.length;
    channelCount.textContent = networkInfo.channels.length;
    ordererInfo.textContent = networkInfo.orderer.endpoint;
    
    log('Network info loaded', 'info');
  } catch (err) {
    log(`Failed to load network info: ${err.message}`, 'error');
  }
}

// ---- 8) Asset Management ----
async function loadAssets() {
  const org = orgSelect.value;
  const channel = channelSelect.value;
  
  if (!org || !channel) {
    alert('Please select both organization and channel');
    return;
  }
  
  currentOrg = org;
  currentChannel = channel;
  
  try {
    assetsBody.innerHTML = '<tr><td colspan="6" class="empty">Loading...</td></tr>';
    
    const res = await fetch(`/api/assets?org=${org}&channel=${channel}`);
    const data = await res.json();
    
    if (!res.ok) {
      throw new Error(data.error || 'Failed to load assets');
    }
    
    renderAssets(data.assets || []);
    log(`Loaded ${data.assets?.length || 0} assets from ${channel} (org${org})`, 'success');
  } catch (err) {
    assetsBody.innerHTML = `<tr><td colspan="6" class="empty">${err.message}</td></tr>`;
    log(`Load failed: ${err.message}`, 'error');
  }
}

function renderAssets(assets) {
  if (!assets || assets.length === 0) {
    assetsBody.innerHTML = '<tr><td colspan="4" class="empty">No records found</td></tr>';
    return;
  }

  // Records differ per channel, so probe the common identifier fields in turn.
  const idOf = (a) => a.id || a.ID || a.subject || a.facility || a.contract || a.ID || a.id || '–';
  const detailsOf = (a) => {
    const skip = new Set(['id','ID','subject','contract','facility','payload','ID','id','timestamp','Timestamp']);
    return Object.entries(a)
      .filter(([k]) => !skip.has(k))
      .map(([k, v]) => `${k}: ${v}`)
      .join(' | ') || '–';
  };

  assetsBody.innerHTML = assets.map(asset => {
    const id = idOf(asset);
    return `
    <tr>
      <td>${id}</td>
      <td>${detailsOf(asset)}</td>
      <td>${asset.timestamp || asset.Timestamp || '–'}</td>
      <td>
        <button class="btn" onclick="viewAsset('${id}')">View</button>
        <button class="btn" onclick="editAsset('${id}')">Re-record</button>
      </td>
    </tr>
  `; }).join('');
}

async function viewAsset(id) {
  try {
    const res = await fetch(`/api/assets/${id}?org=${currentOrg}&channel=${currentChannel}`);
    const data = await res.json();
    
    if (!res.ok) throw new Error(data.error);
    
    alert(JSON.stringify(data.asset, null, 2));
    log(`Viewed asset: ${id}`, 'info');
  } catch (err) {
    alert(`Failed to view asset: ${err.message}`);
    log(`View failed: ${err.message}`, 'error');
  }
}

async function editAsset(id) {
  try {
    const res = await fetch(`/api/assets/${id}?org=${currentOrg}&channel=${currentChannel}`);
    const data = await res.json();
    
    if (!res.ok) throw new Error(data.error);
    
    const asset = data.asset;
    document.getElementById('fieldId').value = asset.ID || asset.id || '';
    document.getElementById('fieldId').disabled = true;
    document.getElementById('fieldOwner').value = asset.Owner || '';
    document.getElementById('fieldValue').value = asset.Value || '';
    document.getElementById('fieldSize').value = asset.Size || '';
    
    editingAssetId = id;
    modalTitle.textContent = 'Edit Asset';
    modalOverlay.classList.add('active');
  } catch (err) {
    alert(`Failed to load asset: ${err.message}`);
    log(`Edit load failed: ${err.message}`, 'error');
  }
}

async function deleteAsset(id) {
  if (!confirm(`Delete asset ${id}?`)) return;
  
  try {
    const res = await fetch(`/api/assets/${id}?org=${currentOrg}&channel=${currentChannel}`, {
      method: 'DELETE'
    });
    const data = await res.json();
    
    if (!res.ok) throw new Error(data.error);
    
    log(`Deleted asset: ${id}`, 'success');
    loadAssets();
  } catch (err) {
    alert(`Delete failed: ${err.message}`);
    log(`Delete failed: ${err.message}`, 'error');
  }
}

function openCreateModal() {
  if (!currentOrg || !currentChannel) {
    alert('Please select organization and channel first');
    return;
  }
  
  assetForm.reset();
  document.getElementById('fieldId').disabled = false;
  editingAssetId = null;
  modalTitle.textContent = 'New Asset';
  modalOverlay.classList.add('active');
}

function closeModal() {
  modalOverlay.classList.remove('active');
  editingAssetId = null;
}

async function saveAsset(e) {
  e.preventDefault();
  
  const payload = {
    id: document.getElementById('fieldId').value,
    owner: document.getElementById('fieldOwner').value,
    value: parseInt(document.getElementById('fieldValue').value),
    size: parseInt(document.getElementById('fieldSize').value)
  };
  
  try {
    let res;
    if (editingAssetId) {
      res = await fetch(`/api/assets/${editingAssetId}?org=${currentOrg}&channel=${currentChannel}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
    } else {
      res = await fetch(`/api/assets?org=${currentOrg}&channel=${currentChannel}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
    }
    
    const data = await res.json();
    if (!res.ok) throw new Error(data.error);
    
    log(`${editingAssetId ? 'Updated' : 'Created'} asset: ${payload.id}`, 'success');
    closeModal();
    loadAssets();
  } catch (err) {
    alert(`Save failed: ${err.message}`);
    log(`Save failed: ${err.message}`, 'error');
  }
}

// ---- 9) Transfer Asset ----
async function transferAsset(id) {
  if (!currentOrg || !currentChannel) {
    alert('Please select organization and channel first');
    return;
  }
  
  transferringAssetId = id;
  document.getElementById('transferAssetId').textContent = id;
  document.getElementById('transferNewOwner').value = '';
  transferModal.classList.add('active');
}

function closeTransferModal() {
  transferModal.classList.remove('active');
  transferringAssetId = null;
}

async function saveTransfer(e) {
  e.preventDefault();
  
  const newOwner = document.getElementById('transferNewOwner').value.trim();
  if (!newOwner) {
    alert('Please enter new owner');
    return;
  }
  
  try {
    const res = await fetch(`/api/assets/${transferringAssetId}/transfer?org=${currentOrg}&channel=${currentChannel}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ newOwner })
    });
    
    const data = await res.json();
    if (!res.ok) throw new Error(data.error);
    
    log(`Transferred asset ${transferringAssetId} to ${newOwner}`, 'success');
    closeTransferModal();
    loadAssets();
  } catch (err) {
    alert(`Transfer failed: ${err.message}`);
    log(`Transfer failed: ${err.message}`, 'error');
  }
}

// ---- 10) Asset History ----
async function assetHistory(id) {
  if (!currentOrg || !currentChannel) {
    alert('Please select organization and channel first');
    return;
  }
  
  try {
    historyContent.innerHTML = '<p>Loading history...</p>';
    historyModal.classList.add('active');
    
    const res = await fetch(`/api/assets/${id}/history?org=${currentOrg}&channel=${currentChannel}`);
    const data = await res.json();
    
    if (!res.ok) throw new Error(data.error);
    
    const history = data.history || [];
    
    if (history.length === 0) {
      historyContent.innerHTML = '<p>No history found for this asset.</p>';
      return;
    }
    
    historyContent.innerHTML = history.map(entry => `
      <div class="history-entry">
        <strong>TxID:</strong> ${entry.txId || '–'}<br>
        <strong>Timestamp:</strong> ${entry.timestamp ? new Date(entry.timestamp).toLocaleString() : '–'}<br>
        <strong>Value:</strong> <pre>${JSON.stringify(entry.value, null, 2)}</pre>
      </div>
    `).join('');
    
    log(`Loaded history for asset: ${id}`, 'info');
  } catch (err) {
    historyContent.innerHTML = `<p>Failed to load history: ${err.message}</p>`;
    log(`History load failed: ${err.message}`, 'error');
  }
}

function closeHistoryModal() {
  historyModal.classList.remove('active');
}

// ---- 11) Logging ----
function log(message, level = 'info') {
  const timestamp = new Date().toLocaleTimeString();
  const prefix = level === 'error' ? '❌' : level === 'success' ? '✅' : 'ℹ️';
  const line = `[${timestamp}] ${prefix} ${message}\n`;
  logOutput.textContent = line + logOutput.textContent;
}

// ---- 12) Expose functions globally for inline onclick ----
window.viewAsset = viewAsset;
window.editAsset = editAsset;
window.deleteAsset = deleteAsset;
window.transferAsset = transferAsset;
window.assetHistory = assetHistory;
