'use strict';

const { withGateway } = require('./connection');

// Channel → Chaincode mapping based on channel_contract_map.sh
const CHANNEL_CHAINCODE_MAP = {
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

// ── نگاشت «عملیات تست/دمو» هر کانال به قرارداد و تابع واقعی ──
// انتخاب‌ها عمداً از نوع ledger یا guarded هستند نه selector:
// دکمه دمو نباید سیزده پارامتر علائم حیاتی بخواهد.
// buildArgs(id, data) آرگومان‌های تابع را می‌سازد؛ id کلید رکورد است.
const CHANNEL_TEST_FN = {
  patientchannel:    { chaincode: 'RegisterPatient',       fn: 'RegisterPatient',       buildArgs: (id, d = {}) => [id, String(d.subject ?? 'commit-demo'), String(d.detail ?? 'ثبت اولیه')] },
  clinicalchannel:   { chaincode: 'AppendProgressNote',    fn: 'AppendProgressNote',    buildArgs: (id, d = {}) => [id, String(d.subject ?? 'patient-demo'), String(d.detail ?? 'یادداشت پیشرفت')] },
  admissionchannel:  { chaincode: 'DischargePatient',      fn: 'DischargePatient',      buildArgs: (id, d = {}) => [id, String(d.subject ?? 'patient-demo'), String(d.detail ?? 'ترخیص')] },
  bedchannel:        { chaincode: 'ReportBedCensus',       fn: 'ReportBedCensus',       buildArgs: (id, d = {}) => [id, String(d.subject ?? 'facility-1'), String(d.detail ?? 'سرشماری تخت')] },
  surgerychannel:    { chaincode: 'RecordSurgicalOutcome', fn: 'RecordSurgicalOutcome', buildArgs: (id, d = {}) => [id, String(d.subject ?? 'case-demo'), String(d.detail ?? 'نتیجه جراحی')] },
  equipmentchannel:  { chaincode: 'RegisterDevice',        fn: 'RegisterDevice',        buildArgs: (id, d = {}) => [id, String(d.subject ?? 'device-demo'), String(d.detail ?? 'ثبت دستگاه')] },
  pharmacychannel:   { chaincode: 'RegisterDrugBatch',     fn: 'RegisterDrugBatch',     buildArgs: (id, d = {}) => [id, String(d.subject ?? 'batch-demo'), String(d.detail ?? 'ثبت بچ')] },
  bloodchannel:      { chaincode: 'RegisterBloodUnit',     fn: 'RegisterBloodUnit',     buildArgs: (id, d = {}) => [id, String(d.subject ?? 'unit-demo'), String(d.detail ?? 'ثبت واحد خون')] },
  labchannel:        { chaincode: 'RecordLabResult',       fn: 'RecordLabResult',       buildArgs: (id, d = {}) => [id, String(d.subject ?? 'order-demo'), String(d.detail ?? 'نتیجه آزمایش')] },
  imagingchannel:    { chaincode: 'RecordImagingReport',   fn: 'RecordImagingReport',   buildArgs: (id, d = {}) => [id, String(d.subject ?? 'study-demo'), String(d.detail ?? 'گزارش تصویربرداری')] },
  staffchannel:      { chaincode: 'RegisterStaff',         fn: 'RegisterStaff',         buildArgs: (id, d = {}) => [id, String(d.subject ?? 'staff-demo'), String(d.detail ?? 'ثبت کارکنان')] },
  referralchannel:   { chaincode: 'AcceptReferral',        fn: 'AcceptReferral',        buildArgs: (id, d = {}) => [id, String(d.subject ?? 'ref-demo'), String(d.detail ?? 'پذیرش ارجاع')] },
  emergencychannel:  { chaincode: 'ReleaseAmbulance',      fn: 'ReleaseAmbulance',      buildArgs: (id, d = {}) => [id, String(d.subject ?? 'amb-demo'), String(d.detail ?? 'آزادسازی آمبولانس')] },
  insurancechannel:  { chaincode: 'RecordCoveragePolicy',  fn: 'RecordCoveragePolicy',  buildArgs: (id, d = {}) => [id, String(d.subject ?? 'policy-demo'), String(d.detail ?? 'ثبت پوشش')] },
  supplychannel:     { chaincode: 'ReportStockLevel',      fn: 'ReportStockLevel',      buildArgs: (id, d = {}) => [id, String(d.subject ?? 'item-demo'), String(d.detail ?? 'سطح موجودی')] },
  marketchannel:     { chaincode: 'MintResourceToken',     fn: 'MintResourceToken',     buildArgs: (id, d = {}) => [String(d.owner ?? id), String(d.amount ?? 1000)] },
  consentchannel:    { chaincode: 'GrantConsent',          fn: 'GrantConsent',          buildArgs: (id, d = {}) => [id, String(d.subject ?? 'commit-demo'), String(d.detail ?? 'اعطای رضایت')] },
  auditchannel:      { chaincode: 'LogSystemAudit',        fn: 'LogSystemAudit',        buildArgs: (id, d = {}) => [id, String(d.subject ?? 'system'), String(d.detail ?? 'تغییر پیکربندی')] },
  compliancechannel: { chaincode: 'ReportIncident',        fn: 'ReportIncident',        buildArgs: (id, d = {}) => [id, String(d.subject ?? 'incident-demo'), String(d.detail ?? 'گزارش رخداد')] },
  analyticschannel:  { chaincode: 'ReportOccupancy',       fn: 'ReportOccupancy',       buildArgs: (id, d = {}) => [id, String(d.subject ?? 'facility-1'), String(d.detail ?? 'اشغال')] },
};

// Generic query function with automatic resource cleanup
async function queryChaincode(orgNum, channelName, chaincodeName, functionName, args = []) {
  return withGateway(orgNum, async (gateway) => {
    const network = gateway.getNetwork(channelName);
    const contract = network.getContract(chaincodeName);
    const resultBytes = await contract.evaluateTransaction(functionName, ...args);
    const resultString = Buffer.from(resultBytes).toString('utf8');
    return resultString ? JSON.parse(resultString) : null;
  });
}

// invoke از طریق gateway. سیاست endorsement این قراردادها در عمل «یک سازمان»
// است (تأییدشده: invoke بدون --peerAddresses فقط با endorse org1 مقدار VALID می‌گیرد)،
// پس endorsingOrganizations را مشخص نمی‌کنیم تا gateway از peer در دسترس خودش
// (همان سازمان کلاینت) endorse بگیرد. تعیین صریح همه ۸ سازمان بدون anchor peer
// به «failed to find any endorsing peers» منجر می‌شد، چون gossip/discovery بین
// سازمان‌ها برقرار نیست.
async function invokeChaincode(orgNum, channelName, chaincodeName, functionName, args = []) {
  return withGateway(orgNum, async (gateway) => {
    const network = gateway.getNetwork(channelName);
    const contract = network.getContract(chaincodeName);
    const resultBytes = await contract.submitTransaction(functionName, ...args);
    const resultString = Buffer.from(resultBytes).toString('utf8');
    return resultString ? JSON.parse(resultString) : { success: true };
  });
}

// Helper: Get primary chaincode for a channel (first in list)
function getChaincodeForChannel(channelName) {
  const chaincodes = CHANNEL_CHAINCODE_MAP[channelName];
  if (!chaincodes || chaincodes.length === 0) {
    throw new Error(`No chaincode mapping found for channel: ${channelName}`);
  }
  return chaincodes[0];
}

// Helper: Get all chaincodes for a channel
function getAllChaincodesForChannel(channelName) {
  const chaincodes = CHANNEL_CHAINCODE_MAP[channelName];
  if (!chaincodes) {
    throw new Error(`No chaincode mapping found for channel: ${channelName}`);
  }
  return chaincodes;
}

function getTestOp(channelName) {
  const op = CHANNEL_TEST_FN[channelName];
  if (!op) throw new Error(`No test operation defined for channel: ${channelName}`);
  return op;
}

// ── High-level API — نگاشت‌شده به توابع واقعی قراردادهای تولیدی ──
// همه ۸۶ قرارداد این دو تابع خواندن را دارند: QueryAsset(id) و QueryAllAssets()

// Query all assets on a channel (real fn: QueryAllAssets)
async function getAllAssets(orgNum, channelName, chaincodeName = null) {
  const cc = chaincodeName || getTestOp(channelName).chaincode;
  return queryChaincode(orgNum, channelName, cc, 'QueryAllAssets');
}

// Query a single asset by ID (real fn: QueryAsset)
async function getAsset(orgNum, channelName, assetId, chaincodeName = null) {
  const cc = chaincodeName || getTestOp(channelName).chaincode;
  return queryChaincode(orgNum, channelName, cc, 'QueryAsset', [assetId]);
}

// Create a record via the channel's real write function.
// assetData: { ID, ...fields } — فیلدهای اضافی به buildArgs همان کانال پاس می‌شوند.
async function createAsset(orgNum, channelName, assetData = {}, chaincodeName = null) {
  const op = getTestOp(channelName);
  const cc = chaincodeName || op.chaincode;
  const id = assetData.ID || assetData.id || `asset-${Date.now()}`;
  return invokeChaincode(orgNum, channelName, cc, op.fn, op.buildArgs(id, assetData));
}

// Update = re-record با همان کلید (قراردادها blind write هستند؛ نسخه جدید جایگزین می‌شود)
async function updateAsset(orgNum, channelName, assetId, assetData = {}, chaincodeName = null) {
  const op = getTestOp(channelName);
  const cc = chaincodeName || op.chaincode;
  return invokeChaincode(orgNum, channelName, cc, op.fn, op.buildArgs(assetId, assetData));
}

// عملیات‌های زیر در قراردادهای تولیدی 6G وجود ندارند — خطای شفاف به جای خطای گنگ chaincode
async function deleteAsset() {
  throw new Error('Delete is not supported by the 6G contracts (no Delete function in any of the 86 chaincodes)');
}
async function transferAsset() {
  throw new Error('Transfer is not supported by the 6G contracts');
}
async function getAssetHistory() {
  throw new Error('History is not supported by the 6G contracts (no GetHistoryForKey wrapper implemented)');
}

module.exports = {
  CHANNEL_CHAINCODE_MAP,
  CHANNEL_TEST_FN,
  queryChaincode,
  invokeChaincode,
  getChaincodeForChannel,
  getAllChaincodesForChannel,
  getTestOp,
  getAllAssets,
  getAsset,
  createAsset,
  updateAsset,
  deleteAsset,
  transferAsset,
  getAssetHistory,
};
