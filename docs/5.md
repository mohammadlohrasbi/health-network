# مستند جامع و کامل
# شبکه ملی سلامت مبتنی بر Hyperledger Fabric
## تبدیل پروژه مدیریت شبکه‌های 6G به سامانه ملی اتصال بیمارستان‌ها، درمانگاه‌ها، داروخانه‌ها و مراکز درمانی

**نسخه:** 5.0 (جامع نهایی)  
**تاریخ:** اوت ۲۰۲۶  
**مبتنی بر مخزن اصلی:** https://github.com/mohammadlohrasbi/6g-network-raft  

---

## فهرست مطالب

1. مقدمه و اهداف
2. معماری کلی سامانه
3. سازمان‌ها (۳۵ سازمان)
4. کانال‌ها (۱۰۰+ کانال)
5. قراردادهای هوشمند اصلی (بیش از ۳۵۰ قرارداد)
6. چارچوب توکن‌سازی کامل
7. مدل داده و ساختارهای کلیدی
8. سیاست‌های تأیید (Endorsement Policies)
9. سناریوهای کاربردی کلیدی
10. نقشه راه پیاده‌سازی
11. مزایای سامانه و قابلیت‌های پژوهشی
12. نتیجه‌گیری

---

# ۱. مقدمه و اهداف

پروژه اصلی شما یک شبکه Hyperledger Fabric با ۸ سازمان، ۲۰ کانال و ۸۶ قرارداد هوشمند برای شبیه‌سازی لایه ثبت و اجماع شبکه‌های 6G است. این معماری شامل مدیریت منابع فیزیکی، مدل قطعی، بازار دادوستد منابع و قابلیت بنچمارک است.

هدف این مستند، گسترش کامل آن پروژه به یک **شبکه ملی سلامت** است که بیمارستان‌ها، درمانگاه‌ها، داروخانه‌ها، آزمایشگاه‌ها، مراکز تصویربرداری و سایر نهادهای مرتبط یک کشور را به هم متصل کند.

### اهداف اصلی سامانه
- ایجاد دفتر کل مشترک و غیرقابل‌انکار بین تمام ذی‌نفعان سلامت کشور
- مدیریت پویا و بهینه منابع فیزیکی و انسانی در سطح محلی، منطقه‌ای و ملی
- کنترل دقیق دسترسی و رضایت بیمار
- پشتیبانی از تریاژ، ارجاع و تخصیص اولویت‌دار
- ایجاد بازار شفاف منابع با قابلیت توکن‌سازی
- ردیابی کامل دارو، خون و تجهیزات از مبدأ تا مصرف
- امکان ممیزی کامل برای نهادهای نظارتی
- حفظ قابلیت بنچمارک و ارزیابی عملکرد

### مقیاس نهایی سامانه
- **۳۵ سازمان**
- **بیش از ۱۰۰ کانال**
- **بیش از ۳۵۰ قرارداد هوشمند اصلی**
- **۱۲ نوع توکن + بیش از ۶۰ قرارداد توکن‌سازی**
- معماری سلسله‌مراتبی (محلی → منطقه‌ای → ملی)

---

# ۲. معماری کلی سامانه

سامانه در سه سطح طراحی شده است:

- **سطح محلی**: هر مرکز درمانی کانال‌ها و قراردادهای خصوصی خود را دارد.
- **سطح منطقه‌ای**: هماهنگی بین مراکز یک استان یا منطقه.
- **سطح ملی**: شاخص بیمار، ردیابی دارو، بازار ملی، بحران و نظارت.

### مؤلفه‌های اصلی
| مؤلفه | مقدار پیشنهادی | توضیح |
|-------|----------------|--------|
| سازمان‌ها | ۳۵ | لایه‌بندی ملی، منطقه‌ای، مراکز درمانی و پشتیبانی |
| Orderer | ۱ تا ۳ (Raft) | مرکز کنترل یا کنسرسیوم |
| کانال‌ها | بیش از ۱۰۰ | محلی + منطقه‌ای + ملی + توکن |
| قراردادهای اصلی | بیش از ۳۵۰ | الگوی Init + تابع اصلی + Query + Validate |
| توکن‌ها | ۱۲ نوع | Bed، OR، Drug، Blood، Staff، Consent، Claim و ... |
| مدل قطعی | موقعیت مکانی + ظرفیت + اولویت | جایگزین مدل رادیویی |
| داشبورد | محلی + منطقه‌ای + ملی | وضعیت منابع، آلارم، KPI و بازار |
| بنچمارک | Tape + Caliper | سناریوهای واقعی بیمارستانی و ملی |

---

# ۳. سازمان‌ها (۳۵ سازمان)

### لایه ملی و نظارتی (۵ سازمان)
- **Org1 – وزارت بهداشت / سازمان نظام پزشکی**: بالاترین مرجع سیاست‌گذاری و نظارت. تعریف استانداردها، تصویب پروتکل‌ها و تأیید نهایی تغییرات کانال‌های ملی.
- **Org2 – سازمان بیمه سلامت و بیمه‌های پایه**: تأیید استحقاق بیمه و پردازش مطالبات ملی. نقش کلیدی در تسویه حساب بین‌مرکزی.
- **Org3 – سازمان غذا و دارو**: ردیابی کامل زنجیره تأمین دارو و تجهیزات از تولید تا مصرف. مسئول فراخوانی ملی.
- **Org4 – مرکز مدیریت آمار و فناوری اطلاعات سلامت**: مدیریت شاخص ملی بیمار و استانداردسازی داده‌ها.
- **Org5 – مرکز فوریت‌های پزشکی (اورژانس ۱۱۵)**: هماهنگی فوریت‌های پیش‌بیمارستانی و انتقال بیماران در سطح ملی.

### لایه منطقه‌ای / استانی (۷ سازمان)
- **Org6 تا Org8 – دانشگاه‌های علوم پزشکی استان‌ها**: هماهنگی مراکز تحت پوشش هر استان، ارجاع منطقه‌ای و نظارت کیفیت.
- **Org9 – شبکه بیمارستان‌های دولتی منطقه**: مدیریت تجمیعی ظرفیت و ارجاع دولتی.
- **Org10 – شبکه بیمارستان‌های خصوصی منطقه**: مشارکت بخش خصوصی و عرضه ظرفیت مازاد.
- **Org11 – شبکه بهداشت و درمان استان**: نمایندگی مراکز بهداشت و خانه‌های بهداشت.
- **Org12 – ستاد هدایت درمان منطقه‌ای**: هدایت ارجاع و انتقال بیماران در سطح منطقه.

### لایه مراکز درمانی (۱۳ سازمان)
- **Org13 – بیمارستان‌های مرجع و تخصصی (سطح ۳)**
- **Org14 – بیمارستان‌های عمومی (سطح ۲)**
- **Org15 – درمانگاه‌ها و کلینیک‌های تخصصی**
- **Org16 – مراکز بهداشت و خانه‌های بهداشت**
- **Org17 – داروخانه‌های بیمارستانی**
- **Org18 – داروخانه‌های شهری و زنجیره‌ای**
- **Org19 – آزمایشگاه‌های مرجع و خصوصی**
- **Org20 – مراکز تصویربرداری مستقل**
- **Org21 – مراکز تله‌مدیسین و مراقبت در منزل**
- **Org22 – مراکز توانبخشی و فیزیوتراپی**
- **Org23 – مراکز سلامت روان**
- **Org24 – مراکز دندان‌پزشکی**
- **Org25 – مراکز دیالیز و بیماران خاص**

### لایه پشتیبانی و زنجیره تأمین (۱۰ سازمان)
- **Org26 – شرکت‌های توزیع دارو**
- **Org27 – تولیدکنندگان دارو**
- **Org28 – تولیدکنندگان و واردکنندگان تجهیزات پزشکی**
- **Org29 – سازمان انتقال خون**
- **Org30 – مراکز فوریت‌های پیش‌بیمارستانی**
- **Org31 – شرکت‌های بیمه تکمیلی**
- **Org32 – انجمن‌های علمی و نظام پزشکی**
- **Org33 – مراکز تحقیقاتی و دانشگاهی**
- **Org34 – سازمان استاندارد و کنترل کیفیت**
- **Org35 – مرکز ملی پاسخ به بحران سلامت**

---

# ۴. کانال‌ها (بیش از ۱۰۰ کانال)

### گروه A – بیمار و داده بالینی محلی (۱۴ کانال)
PatientChannel، ConsentChannel، MedicalHistoryChannel، AllergyChannel، DiagnosisChannel، PrescriptionChannel، LabResultChannel، ImagingChannel، VitalSignsChannel، ProgressNoteChannel، PathologyChannel، GenomicDataChannel، MentalHealthChannel، PediatricChannel

### گروه B – منابع فیزیکی محلی (۱۴ کانال)
BedChannel، ORChannel، ICUChannel، NICUChannel، EquipmentChannel، DeviceChannel، MedicationChannel، ConsumableChannel، RoomChannel، ParkingChannel، EnergyChannel، SterilizationChannel، AmbulanceChannel، BloodBankChannel

### گروه C – نیروی انسانی محلی (۹ کانال)
StaffChannel، ShiftChannel، AttendanceChannel، SkillChannel، WorkloadChannel، TrainingChannel، OnCallChannel، CredentialingChannel، PerformanceChannel

### گروه D – فرآیندهای عملیاتی محلی (۱۲ کانال)
AppointmentChannel، AdmissionChannel، TriageChannel، TransferChannel، DischargeChannel، ReferralChannel، EmergencyChannel، SurgeryScheduleChannel، PostOpChannel، HomeCareChannel، RehabilitationChannel، PalliativeChannel

### گروه E – مالی و تأمین محلی (۹ کانال)
BillingChannel، InsuranceChannel، PaymentChannel، CostCenterChannel، ProcurementChannel، InventoryValueChannel، ClaimAppealChannel، BudgetChannel، VendorChannel

### گروه F – امنیت و انطباق محلی (۹ کانال)
AccessControlChannel، AuditChannel، ComplianceChannel، PrivacyChannel، IdentityChannel، IncidentChannel، DataRetentionChannel، BreakGlassChannel، RegulatoryReportChannel

### گروه G – IoT و تحلیل محلی (۸ کانال)
IoTChannel، TelemedicineChannel، AnalyticsChannel، AIModelChannel، IntegrationChannel، InterHospitalChannel، MarketChannel، CapacityForecastChannel

### گروه H – کانال‌های منطقه‌ای (۱۵ کانال)
RegionalPatientExchangeChannel، RegionalBedCapacityChannel، RegionalReferralChannel، RegionalEmergencyChannel، RegionalLabSharingChannel، RegionalImagingSharingChannel، RegionalPharmacyChannel، RegionalStaffSharingChannel، RegionalTransferChannel، RegionalInsuranceChannel، RegionalProcurementChannel، RegionalAuditChannel، RegionalCapacityForecastChannel، RegionalTelemedicineChannel، RegionalMarketChannel

### گروه I – کانال‌های ملی (۲۰ کانال)
NationalPatientIndexChannel، NationalConsentChannel، NationalReferralNetworkChannel، NationalEmergencyCoordinationChannel، NationalBedRegistryChannel، NationalPharmacySupplyChannel، NationalDrugTraceabilityChannel، NationalBloodInventoryChannel، NationalInsuranceEligibilityChannel، NationalClaimSettlementChannel، NationalDeviceRegistryChannel، NationalStaffCredentialChannel، NationalOutbreakSurveillanceChannel، NationalTelemedicineHubChannel، NationalAnalyticsChannel، NationalAIModelRegistryChannel، NationalMarketChannel، NationalComplianceChannel، NationalAuditChannel، NationalCrisisResourceChannel

### گروه J – کانال‌های توکن‌سازی (۸ کانال)
TokenChannel، ResourceTokenChannel، DrugTokenChannel، StaffTokenChannel، ClaimTokenChannel، ConsentTokenChannel، CrisisTokenChannel، TokenMarketChannel

---

# ۵. قراردادهای هوشمند اصلی (خلاصه گروه‌ها)

### ۵.۱ بیمار و داده بالینی (۴۵ قرارداد)
RegisterPatient، UpdatePatientDemographics، CreateMedicalRecord، AppendProgressNote، RecordDiagnosis، RecordAllergy، GrantConsent، RevokeConsent، ShareDataWithProvider، QueryPatientHistory، ValidateConsentScope، AnonymizePatientData، MergeDuplicateRecords، ArchivePatientRecord، EmergencyBreakGlassAccess، RecordPatientPreference، LinkFamilyMember، RecordGenomicData، RecordMentalHealthNote، CreatePediatricRecord، UpdateImmunization، RecordAdvanceDirective، QueryConsentHistory، TransferPatientOwnership، FlagSensitiveData، RequestDataExport، ApproveDataExport، RecordSecondOpinion، LinkExternalRecord، ValidateIdentityMatch، SoftDeletePatient، RestorePatientRecord، GeneratePatientSummary، RecordLanguagePreference، SetDataSharingLevel، RecordFamilyHistory، UpdateEmergencyContact، RecordSocialDeterminants، CreateCarePlan، UpdateCarePlan، CloseCarePlan، RecordPatientFeedback، FlagHighRiskPatient، QueryActiveCarePlans، GenerateContinuityReport

### ۵.۲ تخت و ظرفیت فیزیکی (۳۵ قرارداد)
AllocateBed، ReleaseBed، ReserveBed، TransferBed، UpdateBedStatus، QueryAvailableBeds، PredictBedOccupancy، PrioritizeBedAllocation، BlockBedForMaintenance، RecordBedTurnover، SetBedPriorityRule، CalculateOccupancyRate، AllocateICUBed، AllocateNICUBed، ReserveOR، ReleaseOR، UpdateRoomStatus، AllocateAmbulance، TrackAmbulanceLocation، ReserveParking، ReleaseParking، AllocateIsolationRoom، RecordCleaningStatus، SetCapacityThreshold، QueryWardOccupancy، LockBedForTransfer، UnlockBed، CalculateTurnaroundTime، PublishBedCapacity، ReserveRemoteBed، ReleaseRemoteReservation، QueryNationalBedRegistry، UpdateBedType، RecordBedInfectionStatus، GenerateCapacityAlert

### ۵.۳ جراحی و اتاق عمل (۲۵ قرارداد)
ScheduleSurgery، CancelSurgery، RescheduleSurgery، AllocateOR، ReleaseOR، RecordSurgeryStart، RecordSurgeryEnd، AssignSurgicalTeam، CheckOREquipmentReadiness، LogSurgicalComplications، QueryORUtilization، RecordAnesthesiaDetails، PostOpTransfer، RecordImplantUsed، ValidateSurgicalConsent، UpdateSurgicalPriority، RecordBloodLoss، GenerateOperativeNote، RecordSurgeryDelay، AssignAnesthetist، RecordRecoveryStatus، LinkSurgeryToDiagnosis، QueryPendingSurgeries، UpdateOREquipmentList، GenerateSurgeryReport

### ۵.۴ تجهیزات و دستگاه (۳۰ قرارداد)
RegisterMedicalDevice، UpdateDeviceLocation، RecordCalibration، ScheduleMaintenance، ReportDeviceFailure، CheckoutDevice، ReturnDevice، TrackDeviceUsageHours، ValidateDeviceCertification، DecommissionDevice، QueryDeviceHistory، LinkDeviceToPatient، SetDeviceAlertThreshold، RecordSterilizationCycle، ValidateSterilization، TrackInstrumentSet، ReportMissingInstrument، AllocateMobileDevice، ReturnMobileDevice، RecordFirmwareUpdate، FlagDeviceRecall، QueryDeviceAvailability، RegisterNationalDevice، TransferDeviceOwnership، RecordDeviceImplant، VerifyDeviceAuthenticity، UpdateDeviceWarranty، SchedulePreventiveMaintenance، RecordDeviceDowntime، GenerateDeviceUtilizationReport

### ۵.۵ دارو، خون و انبار (۴۰ قرارداد)
ReceiveMedicationBatch، DispenseMedication، ReturnMedication، RecordMedicationAdministration، CheckDrugInteraction، TrackExpiryDate، QuarantineBatch، TransferStockBetweenWards، GenerateReorderAlert، AuditControlledSubstances، RecordTemperatureLog، ValidatePrescriptionMatch، ReceiveBloodUnit، IssueBloodUnit، ReturnBloodUnit، RecordTransfusion، TrackBloodExpiry، QuarantineBloodUnit، ReceiveConsumable، IssueConsumable، AdjustInventory، RecordWaste، ValidateColdChain، GenerateStockReport، RegisterDrugBatchNational، TransferDrugOwnership، DispenseNationalTrackedDrug، ReportAdverseDrugEvent، QuarantineNationalBatch، VerifyDrugAuthenticity، TrackMedicalDeviceNational، UpdateNationalPharmacyStock، RequestDrugResupply، ApproveDrugTransfer، RecordDrugRecall، GenerateNationalDrugReport، LinkPrescriptionToDispense، ValidateInsuranceDrugCoverage، RecordPatientDrugHistory، FlagDrugShortage

### ۵.۶ نیروی انسانی (۳۰ قرارداد)
RegisterStaff، AssignShift، RecordAttendance، RequestLeave، ApproveLeave، UpdateSkillCertificate، CalculateWorkloadScore، AssignOnCallDuty، ValidateStaffCompetency، RecordTrainingCompletion، TransferStaffTemporarily، QueryAvailableSpecialists، RecordPerformanceReview، SuspendStaffAccess، ReinstateStaffAccess، AssignMentor، RecordCME، UpdateLicenseStatus، CalculateOvertime، QueryStaffLocation، RegisterNationalStaffCredential، VerifyStaffLicense، SuspendNationalCredential، QueryStaffAvailabilityNational، RecordCrossFacilityDuty، UpdateSpecialty، RecordMalpracticeFlag، ApproveLocumTenens، GenerateStaffingReport، CalculateBurnoutRisk

### ۵.۷ پذیرش، تریاژ و جریان بیمار (۳۰ قرارداد)
AdmitPatient، DischargePatient، TransferPatient، CreateReferral، AcceptReferral، RecordTriageScore، UpdatePatientLocation، GenerateDischargeSummary، ScheduleFollowUp، CloseEpisodeOfCare، EscalateTriageLevel، RecordArrivalTime، RecordDepartureTime، CreateHomeCarePlan، AssignRehabilitation، RecordPalliativeDecision، UpdateCareLevel، LinkEpisodeToDiagnosis، GenerateTransferNote، ValidateDischargeCriteria، CreateNationalReferral، AcceptNationalReferral، RejectNationalReferral، TrackReferralStatus، CoordinatePatientTransfer، RecordTransferHandover، UpdateReceivingFacilityStatus، RecordMassCasualtyTriage، GenerateReferralAnalytics، FlagDelayedTransfer

### ۵.۸ مالی، بیمه و تأمین (۳۵ قرارداد)
GenerateInvoice، SubmitInsuranceClaim، ProcessClaimResponse، RecordPayment، AdjustBilling، AllocateCostToCenter، QueryOutstandingBalance، ValidateInsuranceEligibility، CreatePaymentPlan، ReconcilePayments، FlagFraudulentClaim، GenerateFinancialReport، CreatePurchaseOrder، ReceiveGoods، ApproveInvoice، RecordVendorPayment، UpdateBudget، AllocateBudget، AppealClaim، RecordCopay، GenerateCostReport، FlagHighCostCase، CheckNationalEligibility، SubmitNationalClaim، AdjudicateClaim، SettleClaimPayment، AppealNationalClaim، ReconcileFacilityPayments، FlagSuspiciousClaimPattern، RecordNationalPayment، GenerateNationalFinancialSummary، UpdateVendorContract، RecordProcurementApproval، TrackInvoiceStatus، CalculateFacilityRevenue

### ۵.۹ دسترسی، امنیت و انطباق (۳۰ قرارداد)
GrantRoleAccess، RevokeRoleAccess، LogAccessAttempt، BreakGlassAccess، ReviewAccessLog، UpdatePrivacyPreference، EnforceDataRetentionPolicy، DetectAnomalousAccess، IssueTemporaryCredential، RevokeAllSessions، RecordSecurityIncident، ApproveAccessRequest، SetRetentionPeriod، AnonymizeExpiredData، GenerateComplianceReport، RecordRegulatorySubmission، FlagPolicyViolation، ApproveBreakGlass، QueryAccessHistory، UpdateRoleDefinition، GrantNationalAccess، RevokeNationalAccess، LogNationalAccess، EnforceNationalPrivacy، GenerateNationalAuditReport، RecordCrossFacilityAccess، ValidatePurposeOfUse، FlagUnauthorizedAccess، UpdateNationalRole، GenerateAccessAnalytics

### ۵.۱۰ IoT، تله‌مدیسین و مانیتورینگ (۲۵ قرارداد)
RegisterIoTDevice، IngestVitalSign، RaiseCriticalAlert، AcknowledgeAlert، ConfigureAlertThreshold، AggregateSensorData، ValidateDeviceFirmware، LinkDeviceToPatient، QueryDeviceStream، ArchiveSensorData، SetPatientMonitoringProfile، DetectAbnormalPattern، StartTelemedicineSession، EndTelemedicineSession، RecordRemoteConsultation، ShareLiveVitals، ConfigureHomeMonitor، RaiseHomeAlert، RegisterNationalIoTDevice، StreamNationalVitals، CoordinateRemoteMonitoring، RecordTelemedicineOutcome، LinkDeviceToNationalID، GenerateMonitoringReport، FlagDeviceMalfunction

### ۵.۱۱ تحلیل، هوش مصنوعی و پژوهش (۲۰ قرارداد)
SubmitAnonymizedDataset، RegisterAIModel، ValidateModelVersion، RequestInterHospitalData، ApproveDataExchange، LogDataUsage، CalculateKPI، ShareBedCapacity، RequestEquipmentLoan، PublishCapacityForecast، AcceptCapacityOffer، RecordModelInference، FlagModelDrift، QuerySharedCapacity، SubmitAnonymizedNationalDataset، RegisterNationalAIModel، ValidateNationalModel، RequestResearchAccess، ApproveResearchDataset، LogResearchUsage

### ۵.۱۲ بازار منابع کلاسیک (۲۵ قرارداد)
OfferBedCapacity، OfferEquipmentTime، OfferLabCapacity، OfferStaffTime، OfferORSlot، OfferBloodUnit، AcceptResourceOffer، SettleResourceTrade، RecordResourcePayment، ValidateResourceOwnership، CancelResourceListing، RateResourceProvider، QueryMarketListings، LockResourceForTrade، ReleaseResourceLock، UpdateOfferPrice، ExpireOffer، GenerateMarketReport، OfferNationalBedCapacity، OfferNationalEquipment، OfferNationalLabSlot، OfferNationalStaff، AcceptNationalOffer، SettleNationalTrade، RateNationalProvider

### ۵.۱۳ بحران، اپیدمی و فوریت ملی (۲۰ قرارداد)
DeclareRegionalEmergency، ActivateCrisisProtocol، AllocateCrisisResources، TrackAmbulanceFleet، CoordinateMassCasualty، ReportOutbreakCase، ShareOutbreakData، RequestNationalSupport، DeclareNationalEmergency، ActivateNationalCrisisMode، AllocateNationalResources، TrackNationalAmbulance، CoordinateNationalResponse، ReportNationalOutbreak، UpdateOutbreakStatus، RequestMilitarySupport، ReleaseCrisisResources، GenerateCrisisReport، FlagResourceShortage، CoordinateVaccinationCampaign

---

# ۶. چارچوب توکن‌سازی کامل

### ۶.۱ انواع توکن (۱۲ نوع)
BedToken، ORToken، EquipmentToken، DrugToken، BloodToken، StaffToken، LabToken، ConsentToken، ClaimToken، PaymentToken، CapacityCredit، CrisisToken

### ۶.۲ کانال‌های توکن (۸ کانال)
TokenChannel، ResourceTokenChannel، DrugTokenChannel، StaffTokenChannel، ClaimTokenChannel، ConsentTokenChannel، CrisisTokenChannel، TokenMarketChannel

### ۶.۳ قراردادهای توکن‌سازی (بیش از ۶۰ قرارداد)
MintToken، BurnToken، TransferToken، LockToken، UnlockToken، ExpireToken، QueryToken، QueryTokenBalance، QueryTokenHistory، UpdateTokenMetadata،  
MintBedToken، BurnBedToken، MintORToken، BurnORToken، MintEquipmentToken، BurnEquipmentToken، MintLabToken، BurnLabToken،  
MintDrugToken، BurnDrugToken، MintBloodToken، BurnBloodToken، ExpireDrugOrBloodToken، QuarantineToken،  
MintStaffToken، BurnStaffToken، TransferStaffToken،  
MintConsentToken، UseConsentToken، RevokeConsentToken، QueryConsentTokenStatus،  
MintClaimToken، UpdateClaimTokenStatus، ConvertClaimToPayment، MintPaymentToken، TransferPaymentToken، BurnPaymentToken،  
MintCrisisToken، UseCrisisToken، ExpireCrisisToken،  
ListTokenForSale، CancelTokenListing، BuyToken، SettleTokenTrade، QueryMarketListings، LockTokenForTrade، ReleaseTokenLock، UpdateTokenPrice، RateTokenProvider، GenerateTokenMarketReport،  
SplitToken، MergeTokens، FreezeToken، UnfreezeToken، AuditToken، BatchMintTokens، BatchTransferTokens، QueryExpiringTokens، ValidateTokenRules، LinkTokenToRealAsset

### ۶.۴ ساختار داده توکن (Go)
```go
type Token struct {
    TokenID         string
    TokenType       string
    OwnerMSP        string
    IssuerMSP       string
    Amount          int64
    Metadata        map[string]string
    Status          string // ACTIVE, LOCKED, BURNED, EXPIRED, QUARANTINED
    IssuedAt        string
    ExpiresAt       string
    ParentTokenID   string
    TransferHistory []TransferRecord
}
```

---

# ۷. مدل داده و نکات فنی کلیدی

- تمام قراردادها از الگوی یکنواخت پروژه اصلی پیروی می‌کنند (Init + تابع اصلی + Query + Validate).
- محاسبات ظرفیت، اولویت و انقضا باید کاملاً قطعی (integer-based) باشند تا مشکل endorsement policy failure رخ ندهد.
- از Private Data Collections برای داده‌های بسیار حساس (ژنتیکی، سلامت روان، ConsentToken) استفاده شود.
- همگام‌سازی وضعیت فیزیکی (تخت، دارو) با وضعیت توکن الزامی است.

---

# ۸. سیاست‌های تأیید پیشنهادی

- کانال‌های محلی: OR اعضای مرکز
- کانال‌های منطقه‌ای: حداقل ۲ سازمان مختلف + سازمان منطقه‌ای
- کانال‌های ملی حساس: AND بین وزارت بهداشت + بیمه + مبدأ + مقصد
- Mint توکن‌های ملی و CrisisToken: حداقل دو سازمان ملی
- عملیات بازار: تأیید دو طرف معامله + قرارداد بازار

---

# ۹. سناریوهای کاربردی کلیدی

1. تریاژ و تخصیص تخت با توکن در اورژانس
2. ارجاع ملی بیمار + رزرو تخت از راه دور با BedToken
3. ردیابی کامل دارو از کارخانه تا بیمار با DrugToken
4. بازار ملی ظرفیت تخت و تجهیزات در زمان پیک
5. تسویه تقریباً بلادرنگ مطالبات بیمه‌ای با ClaimToken → PaymentToken
6. مدیریت بحران و تخصیص اولویت‌دار با CrisisToken
7. رضایت دقیق بیمار با ConsentToken و کنترل دسترسی
8. اشتراک نیروی انسانی متخصص بین مراکز با StaffToken

---

# ۱۰. نقشه راه پیاده‌سازی

**فاز ۱ (۴–۶ ماه)**  
پیاده‌سازی کامل در یک بیمارستان + چند درمانگاه و داروخانه همکار + توکن‌های Bed و OR

**فاز ۲ (۶–۹ ماه)**  
گسترش به یک استان (شبکه منطقه‌ای) + توکن دارو و خون + ConsentToken

**فاز ۳ (۹–۱۵ ماه)**  
اتصال چند استان + کانال‌های ملی کلیدی + بازار منطقه‌ای و Claim/Payment Token

**فاز ۴ (۱۵–۲۴ ماه)**  
پوشش سراسری + CrisisToken + بازار ملی کامل + بهینه‌سازی عملکرد و بنچمارک

---

# ۱۱. مزایای سامانه و قابلیت‌های پژوهشی

- حفظ کامل زیرساخت فنی پروژه 6G فعلی → کاهش زمان توسعه
- موضوع داغ و قابل انتشار در مجلات بلاکچین، سلامت دیجیتال و مدیریت منابع
- امکان مقایسه مستقیم با معماری 6G قبلی
- مقیاس‌پذیری واقعی به شبکه بیمارستانی ملی
- پشتیبانی قوی از الزامات حریم خصوصی، ممیزی و توکن‌سازی منابع

---

# ۱۲. نتیجه‌گیری

این مستند جامع، نقشه راه کامل تبدیل پروژه Hyperledger Fabric مدیریت شبکه‌های 6G به یک **شبکه ملی سلامت** با قابلیت‌های پیشرفته مدیریت منابع، ردیابی، بازار و توکن‌سازی را ارائه می‌دهد.

تمام اجزای اصلی شامل:
- ۳۵ سازمان
- بیش از ۱۰۰ کانال
- بیش از ۳۵۰ قرارداد هوشمند
- چارچوب کامل توکن‌سازی (۱۲ نوع توکن + ۶۰+ قرارداد)

در یک سند واحد گردآوری شده است و آماده استفاده به عنوان پایه پروپوزال، فصل معماری پایان‌نامه، مستندات فنی یا طرح اجرایی پروژه می‌باشد.

---

**پایان مستند جامع**  
آماده دانلود و استفاده.
