'use strict';

/* تولیدشده خودکار توسط scripts/gen-hospital-contracts.js — دستی ویرایش نکنید.
   منبع: scripts/channel_contract_map.sh

   برخلاف نسخه 6G که این فایل با مهندسی معکوس از کد Go ساخته می‌شد،
   اینجا همان مولدی که chaincode را می‌نویسد این را هم می‌نویسد. پس
   ناهمخوانی امضا با کد ساختاراً ممکن نیست.

   needsSeed  پیش از هر نوشتنی SeedFacilityLayout لازم است
   tapeSafe   false یعنی فقط Caliper — Tape آرگومان ثابت می‌فرستد
   kind       selector | guarded | ledger | market
*/

const CONTRACT_FN = {
  AcceptReferral: { fn: "AcceptReferral", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ActivateCrisisProtocol: { fn: "ActivateCrisisProtocol", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  AdjudicateClaim: { fn: "AdjudicateClaim", params: ["id","claimID","tariffMicro","coverageMilli","deductibleMicro","remainingCapMicro"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  AdmitPatient: { fn: "AdmitPatient", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  AllocateBed: { fn: "AllocateBed", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  AppendProgressNote: { fn: "AppendProgressNote", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  AssignAmbulanceDestination: { fn: "AssignAmbulanceDestination", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  AssignPriority: { fn: "AssignPriority", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  AssignShift: { fn: "AssignShift", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  BalanceOf: { fn: "BalanceOf", params: ["owner"], kind: "market", needsSeed: true, tapeSafe: true, readOnly: true },
  CancelSurgery: { fn: "CancelSurgery", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  CheckConsent: { fn: "CheckConsent", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  CheckDrugInteraction: { fn: "CheckDrugInteraction", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  CloseReferral: { fn: "CloseReferral", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  CreateMedicalRecord: { fn: "CreateMedicalRecord", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  CreateReferral: { fn: "CreateReferral", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  CrossMatchScreen: { fn: "CrossMatchScreen", params: ["id","donorType","recipientType","product"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  DeactivatePatient: { fn: "DeactivatePatient", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  DischargePatient: { fn: "DischargePatient", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  DispatchAmbulance: { fn: "DispatchAmbulance", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  DispenseDrug: { fn: "DispenseDrug", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  EmergencyOverrideAccess: { fn: "EmergencyOverrideAccess", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  FlagCriticalResult: { fn: "FlagCriticalResult", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  GrantConsent: { fn: "GrantConsent", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  IssueBloodUnit: { fn: "IssueBloodUnit", params: ["id","unitID","recipientCommit","donorType","recipientType","product","expirySec"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  LendStaffHours: { fn: "LendStaffHours", params: ["id","from","to","amount","priceMicro"], kind: "market", needsSeed: true, tapeSafe: true, readOnly: false },
  LinkNationalIndex: { fn: "LinkNationalIndex", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogAccessAudit: { fn: "LogAccessAudit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogBloodAudit: { fn: "LogBloodAudit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogClinicalAudit: { fn: "LogClinicalAudit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogDataAccess: { fn: "LogDataAccess", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogDeviceMaintenance: { fn: "LogDeviceMaintenance", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogDrugAudit: { fn: "LogDrugAudit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogFinancialAudit: { fn: "LogFinancialAudit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogPatientAudit: { fn: "LogPatientAudit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  LogSystemAudit: { fn: "LogSystemAudit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  MergeDuplicateRecord: { fn: "MergeDuplicateRecord", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  MintResourceToken: { fn: "MintResourceToken", params: ["owner","amount"], kind: "market", needsSeed: true, tapeSafe: true, readOnly: false },
  OrderImaging: { fn: "OrderImaging", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  OrderLabTest: { fn: "OrderLabTest", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  PrescribeDrug: { fn: "PrescribeDrug", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  QueryPatientSummary: { fn: "QueryPatientSummary", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecallDrugBatch: { fn: "RecallDrugBatch", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  ReceiveShipment: { fn: "ReceiveShipment", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordAccreditation: { fn: "RecordAccreditation", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordAllergy: { fn: "RecordAllergy", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordCoveragePolicy: { fn: "RecordCoveragePolicy", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordCredential: { fn: "RecordCredential", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordDiagnosis: { fn: "RecordDiagnosis", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordDischargeSummary: { fn: "RecordDischargeSummary", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordEdArrival: { fn: "RecordEdArrival", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordImagingReport: { fn: "RecordImagingReport", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordLabResult: { fn: "RecordLabResult", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordProcedure: { fn: "RecordProcedure", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordQualityIndicator: { fn: "RecordQualityIndicator", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordShipment: { fn: "RecordShipment", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordSurgicalOutcome: { fn: "RecordSurgicalOutcome", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RecordVitalSigns: { fn: "RecordVitalSigns", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RegisterBloodUnit: { fn: "RegisterBloodUnit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RegisterDevice: { fn: "RegisterDevice", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RegisterDrugBatch: { fn: "RegisterDrugBatch", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RegisterPatient: { fn: "RegisterPatient", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RegisterStaff: { fn: "RegisterStaff", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RegisterSupplyItem: { fn: "RegisterSupplyItem", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RejectClaim: { fn: "RejectClaim", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RejectReferral: { fn: "RejectReferral", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReleaseAmbulance: { fn: "ReleaseAmbulance", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReleaseBed: { fn: "ReleaseBed", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReleaseDevice: { fn: "ReleaseDevice", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportBedCensus: { fn: "ReportBedCensus", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportBloodInventory: { fn: "ReportBloodInventory", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportDeviceFault: { fn: "ReportDeviceFault", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportEpidemicSignal: { fn: "ReportEpidemicSignal", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportIncident: { fn: "ReportIncident", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportMassCasualty: { fn: "ReportMassCasualty", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportOccupancy: { fn: "ReportOccupancy", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportOutcomeIndicator: { fn: "ReportOutcomeIndicator", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportStockLevel: { fn: "ReportStockLevel", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReportWaitTime: { fn: "ReportWaitTime", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestAdmission: { fn: "RequestAdmission", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestBedCapacity: { fn: "RequestBedCapacity", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestBloodUnit: { fn: "RequestBloodUnit", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestEmergencyOr: { fn: "RequestEmergencyOr", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestImagingSlot: { fn: "RequestImagingSlot", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestLabCapacity: { fn: "RequestLabCapacity", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestOnCall: { fn: "RequestOnCall", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestPrehospitalDestination: { fn: "RequestPrehospitalDestination", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestRestock: { fn: "RequestRestock", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  RequestSpecialistOpinion: { fn: "RequestSpecialistOpinion", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  ReserveDevice: { fn: "ReserveDevice", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  ReserveIcuBed: { fn: "ReserveIcuBed", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  ReserveOrSlot: { fn: "ReserveOrSlot", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  ReturnBloodUnit: { fn: "ReturnBloodUnit", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ReturnDrug: { fn: "ReturnDrug", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RevokeConsent: { fn: "RevokeConsent", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  RevokeCredential: { fn: "RevokeCredential", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ScheduleSurgery: { fn: "ScheduleSurgery", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  SettleClaim: { fn: "SettleClaim", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  ShareBedCapacity: { fn: "ShareBedCapacity", params: ["id","lender","borrower","facilityID","beds","priceMicro"], kind: "market", needsSeed: true, tapeSafe: false, readOnly: false },
  ShareDataWithProvider: { fn: "ShareDataWithProvider", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  SubmitClaim: { fn: "SubmitClaim", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  TradeOrSlot: { fn: "TradeOrSlot", params: ["id","from","to","amount","priceMicro"], kind: "market", needsSeed: true, tapeSafe: true, readOnly: false },
  TransferPatient: { fn: "TransferPatient", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  TransferToken: { fn: "TransferToken", params: ["from","to","amount"], kind: "market", needsSeed: true, tapeSafe: false, readOnly: false },
  TransferWard: { fn: "TransferWard", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  TriagePatient: { fn: "TriagePatient", params: ["id","patientCommit","x","y","rr","spo2","onOxygen","sbp","hr","avpu","tempMilliC","flags","ageYears"], kind: "selector", needsSeed: true, tapeSafe: true, readOnly: false },
  UpdateDemographics: { fn: "UpdateDemographics", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
  VerifyDrugSafety: { fn: "VerifyDrugSafety", params: ["id","drugCode","drugClassMask","allergyMask","weightGrams","minPerKgMicro","maxPerKgMicro","orderedMicro","renalMilli","expirySec"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  VerifyEligibility: { fn: "VerifyEligibility", params: ["id","subject","condition","threshold"], kind: "guarded", needsSeed: true, tapeSafe: true, readOnly: false },
  VerifyProtocolAdherence: { fn: "VerifyProtocolAdherence", params: ["id","subject","detail"], kind: "ledger", needsSeed: true, tapeSafe: true, readOnly: false },
};

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

const READ_ONLY_CONTRACTS = ["BalanceOf"];

module.exports = { CONTRACT_FN, CHANNEL_CHAINCODE_MAP, READ_ONLY_CONTRACTS };
