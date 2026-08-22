# مستند کامل شبکه ملی سلامت با Hyperledger Fabric
## تبدیل پروژه مدیریت شبکه‌های 6G به سامانه ملی اتصال بیمارستان‌ها، درمانگاه‌ها و داروخانه‌ها

**نسخه:** 2.0  
**تاریخ:** اوت ۲۰۲۶  
**مبتنی بر مخزن:** https://github.com/mohammadlohrasbi/6g-network-raft  

---

## ۱. مقدمه

این مستند پیشنهاد کامل تبدیل پروژه Hyperledger Fabric مدیریت شبکه‌های 6G به یک **شبکه ملی سلامت** است. هدف، ایجاد لایه اعتماد و اجماع مشترک بین تمام مراکز درمانی یک کشور (بیمارستان‌ها، درمانگاه‌ها، داروخانه‌ها، آزمایشگاه‌ها و ...) می‌باشد.

**مقیاس نهایی پیشنهادی:**
- **۳۵ سازمان**
- **۱۰۰ کانال**
- **بیش از ۳۵۰ قرارداد هوشمند**

---

## ۲. سازمان‌ها (۳۵ سازمان)

### لایه ملی و نظارتی (۵ سازمان)
| شماره | نام سازمان | توضیح مختصر |
|-------|------------|-------------|
| Org1 | وزارت بهداشت / سازمان نظام پزشکی | سیاست‌گذاری کلان، نظارت و استانداردسازی |
| Org2 | سازمان بیمه سلامت و بیمه‌های پایه | تأیید استحقاق بیمه و تسویه مطالبات |
| Org3 | سازمان غذا و دارو | ردیابی اصالت دارو و تجهیزات پزشکی |
| Org4 | مرکز مدیریت آمار و فناوری اطلاعات سلامت | مدیریت شاخص ملی بیمار و تحلیل داده‌ها |
| Org5 | مرکز فوریت‌های پزشکی (اورژانس ۱۱۵) | هماهنگی بحران، انتقال بیمار و فوریت‌ها |

### لایه منطقه‌ای / استانی (۷ سازمان)
| شماره | نام سازمان | توضیح مختصر |
|-------|------------|-------------|
| Org6 | دانشگاه علوم پزشکی استان A | هماهنگی مراکز تحت پوشش استان |
| Org7 | دانشگاه علوم پزشکی استان B | هماهنگی مراکز تحت پوشش استان |
| Org8 | دانشگاه علوم پزشکی استان C | هماهنگی مراکز تحت پوشش استان |
| Org9 | شبکه بیمارستان‌های دولتی منطقه | مدیریت ظرفیت و ارجاع دولتی |
| Org10 | شبکه بیمارستان‌های خصوصی منطقه | مشارکت بخش خصوصی |
| Org11 | شبکه بهداشت و درمان استان | مراکز بهداشت و خانه‌های بهداشت |
| Org12 | ستاد هدایت درمان منطقه‌ای | هماهنگی ارجاع و انتقال بین‌بیمارستانی |

### لایه مراکز درمانی (۱۳ سازمان)
| شماره | نام سازمان | توضیح مختصر |
|-------|------------|-------------|
| Org13 | بیمارستان‌های مرجع و تخصصی (سطح ۳) | مراکز فوق‌تخصصی و ارجاع نهایی |
| Org14 | بیمارستان‌های عمومی (سطح ۲) | بیمارستان‌های شهرستان و عمومی |
| Org15 | درمانگاه‌ها و کلینیک‌های تخصصی | مراکز سرپایی تخصصی |
| Org16 | مراکز بهداشت و خانه‌های بهداشت | مراقبت‌های اولیه و پیشگیری |
| Org17 | داروخانه‌های بیمارستانی | داروخانه داخل بیمارستان |
| Org18 | داروخانه‌های شهری و زنجیره‌ای | توزیع دارو در سطح جامعه |
| Org19 | آزمایشگاه‌های مرجع و خصوصی | انجام آزمایش‌های تشخیصی |
| Org20 | مراکز تصویربرداری مستقل | رادیولوژی، CT، MRI و سونوگرافی |
| Org21 | مراکز تله‌مدیسین و مراقبت در منزل | ویزیت از راه دور و پایش خانگی |
| Org22 | مراکز توانبخشی و فیزیوتراپی | خدمات توانبخشی |
| Org23 | مراکز سلامت روان | خدمات روان‌پزشکی و مشاوره |
| Org24 | مراکز دندان‌پزشکی | خدمات دندان‌پزشکی |
| Org25 | مراکز دیالیز و بیماران خاص | مراقبت بیماران خاص |

### لایه پشتیبانی و زنجیره تأمین (۱۰ سازمان)
| شماره | نام سازمان | توضیح مختصر |
|-------|------------|-------------|
| Org26 | شرکت‌های توزیع دارو | توزیع دارو در سطح کشور |
| Org27 | تولیدکنندگان دارو | ثبت بچ تولید و اصالت‌سنجی |
| Org28 | تولیدکنندگان و واردکنندگان تجهیزات پزشکی | ثبت و ردیابی تجهیزات |
| Org29 | سازمان انتقال خون | مدیریت خون و فرآورده‌های خونی |
| Org30 | مراکز فوریت‌های پیش‌بیمارستانی | ناوگان آمبولانس |
| Org31 | شرکت‌های بیمه تکمیلی | بیمه‌های خصوصی و تکمیلی |
| Org32 | انجمن‌های علمی و نظام پزشکی | اعتبارسنجی تخصص و گواهینامه |
| Org33 | مراکز تحقیقاتی و دانشگاهی | پژوهش و دسترسی به داده ناشناس |
| Org34 | سازمان استاندارد و کنترل کیفیت | بازرسی و تأیید کیفیت |
| Org35 | مرکز ملی پاسخ به بحران سلامت | هماهنگی در اپیدمی و بلایا |

---

## ۳. کانال‌ها (۱۰۰ کانال)

### گروه A — کانال‌های محلی بیمار و داده بالینی (۱۴ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| PatientChannel | پرونده اصلی بیمار در سطح مرکز |
| ConsentChannel | مدیریت رضایت بیمار |
| MedicalHistoryChannel | سوابق پزشکی بلندمدت |
| AllergyChannel | ثبت آلرژی‌ها و حساسیت‌ها |
| DiagnosisChannel | تشخیص‌ها و کدهای بیماری |
| PrescriptionChannel | نسخه‌ها و دستورات دارویی |
| LabResultChannel | نتایج آزمایشگاه |
| ImagingChannel | تصاویر پزشکی |
| VitalSignsChannel | علائم حیاتی و مانیتورینگ |
| ProgressNoteChannel | گزارش پیشرفت درمان |
| PathologyChannel | نتایج پاتولوژی |
| GenomicDataChannel | داده‌های ژنتیکی |
| MentalHealthChannel | پرونده سلامت روان |
| PediatricChannel | پرونده کودکان |

### گروه B — کانال‌های منابع فیزیکی محلی (۱۴ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| BedChannel | مدیریت تخت‌های بستری |
| ORChannel | اتاق‌های عمل |
| ICUChannel | بخش مراقبت‌های ویژه |
| NICUChannel | بخش نوزادان ویژه |
| EquipmentChannel | تجهیزات پزشکی سنگین |
| DeviceChannel | دستگاه‌های قابل حمل |
| MedicationChannel | دارو و انبار دارویی |
| ConsumableChannel | مواد مصرفی |
| RoomChannel | اتاق‌ها و فضاها |
| ParkingChannel | پارکینگ و دسترسی فیزیکی |
| EnergyChannel | مصرف انرژی |
| SterilizationChannel | استریلیزاسیون ابزار |
| AmbulanceChannel | آمبولانس محلی |
| BloodBankChannel | بانک خون محلی |

### گروه C — کانال‌های نیروی انسانی محلی (۹ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| StaffChannel | اطلاعات پرسنل |
| ShiftChannel | شیفت‌بندی |
| AttendanceChannel | حضور و غیاب |
| SkillChannel | مهارت‌ها و گواهینامه‌ها |
| WorkloadChannel | بار کاری |
| TrainingChannel | آموزش و بازآموزی |
| OnCallChannel | کشیک و آنکال |
| CredentialingChannel | اعتبارسنجی مدارک |
| PerformanceChannel | ارزیابی عملکرد |

### گروه D — کانال‌های فرآیند عملیاتی محلی (۱۲ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| AppointmentChannel | نوبت‌دهی |
| AdmissionChannel | پذیرش |
| TriageChannel | تریاژ |
| TransferChannel | انتقال داخل مرکز |
| DischargeChannel | ترخیص |
| ReferralChannel | ارجاع داخلی |
| EmergencyChannel | مدیریت اورژانس |
| SurgeryScheduleChannel | برنامه‌ریزی جراحی |
| PostOpChannel | مراقبت پس از عمل |
| HomeCareChannel | مراقبت در منزل |
| RehabilitationChannel | توانبخشی |
| PalliativeChannel | مراقبت تسکینی |

### گروه E — کانال‌های مالی و تأمین محلی (۹ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| BillingChannel | صورتحساب |
| InsuranceChannel | بیمه محلی |
| PaymentChannel | پرداخت‌ها |
| CostCenterChannel | مراکز هزینه |
| ProcurementChannel | خرید |
| InventoryValueChannel | ارزش موجودی |
| ClaimAppealChannel | اعتراض به مطالبات |
| BudgetChannel | بودجه مرکز |
| VendorChannel | تأمین‌کنندگان محلی |

### گروه F — کانال‌های امنیت و انطباق محلی (۹ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| AccessControlChannel | کنترل دسترسی |
| AuditChannel | ممیزی عملیات |
| ComplianceChannel | انطباق با قوانین |
| PrivacyChannel | حریم خصوصی |
| IdentityChannel | هویت دیجیتال |
| IncidentChannel | حوادث امنیتی |
| DataRetentionChannel | نگهداری داده |
| BreakGlassChannel | دسترسی اضطراری |
| RegulatoryReportChannel | گزارش نظارتی |

### گروه G — کانال‌های IoT و تحلیل محلی (۸ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| IoTChannel | داده‌های سنسورها |
| TelemedicineChannel | تله‌مدیسین محلی |
| AnalyticsChannel | تحلیل محلی |
| AIModelChannel | مدل‌های هوش مصنوعی |
| IntegrationChannel | یکپارچه‌سازی سیستم‌ها |
| InterHospitalChannel | تبادل محدود بین‌مرکزی |
| MarketChannel | بازار منابع محلی |
| CapacityForecastChannel | پیش‌بینی ظرفیت |

### گروه H — کانال‌های منطقه‌ای (۱۵ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| RegionalPatientExchangeChannel | تبادل پرونده منطقه‌ای |
| RegionalBedCapacityChannel | ظرفیت تخت منطقه‌ای |
| RegionalReferralChannel | ارجاع منطقه‌ای |
| RegionalEmergencyChannel | هماهنگی اورژانس منطقه‌ای |
| RegionalLabSharingChannel | اشتراک آزمایشگاه |
| RegionalImagingSharingChannel | اشتراک تصویربرداری |
| RegionalPharmacyChannel | هماهنگی داروخانه‌ها |
| RegionalStaffSharingChannel | اشتراک نیروی انسانی |
| RegionalTransferChannel | انتقال بیمار منطقه‌ای |
| RegionalInsuranceChannel | بیمه منطقه‌ای |
| RegionalProcurementChannel | خرید متمرکز منطقه‌ای |
| RegionalAuditChannel | ممیزی منطقه‌ای |
| RegionalCapacityForecastChannel | پیش‌بینی ظرفیت منطقه |
| RegionalTelemedicineChannel | تله‌مدیسین منطقه‌ای |
| RegionalMarketChannel | بازار منابع منطقه‌ای |

### گروه I — کانال‌های ملی (۲۰ کانال)
| نام کانال | توضیح مختصر |
|-----------|-------------|
| NationalPatientIndexChannel | شاخص ملی بیمار (شناسه یکتا) |
| NationalConsentChannel | رضایت ملی اشتراک داده |
| NationalReferralNetworkChannel | شبکه ارجاع ملی |
| NationalEmergencyCoordinationChannel | هماهنگی بحران ملی |
| NationalBedRegistryChannel | ثبت ظرفیت تخت ملی |
| NationalPharmacySupplyChannel | تأمین داروی ملی |
| NationalDrugTraceabilityChannel | ردیابی دارو از کارخانه تا بیمار |
| NationalBloodInventoryChannel | موجودی خون ملی |
| NationalInsuranceEligibilityChannel | استحقاق بیمه ملی |
| NationalClaimSettlementChannel | تسویه مطالبات ملی |
| NationalDeviceRegistryChannel | ثبت تجهیزات پزشکی ملی |
| NationalStaffCredentialChannel | اعتبارسنجی پرسنل ملی |
| NationalOutbreakSurveillanceChannel | مراقبت از طغیان بیماری |
| NationalTelemedicineHubChannel | هاب تله‌مدیسین ملی |
| NationalAnalyticsChannel | تحلیل داده‌های ناشناس ملی |
| NationalAIModelRegistryChannel | ثبت مدل‌های هوش مصنوعی |
| NationalMarketChannel | بازار ملی منابع |
| NationalComplianceChannel | انطباق ملی |
| NationalAuditChannel | ممیزی ملی |
| NationalCrisisResourceChannel | تخصیص منابع در بحران |

---

## ۴. قراردادهای هوشمند (بیش از ۳۵۰ قرارداد)

قراردادها بر اساس حوزه دسته‌بندی شده‌اند. الگوی مشترک همه قراردادها حفظ می‌شود:
`Init` + تابع اصلی + `QueryAsset` + `QueryAllAssets` + `Validate...`

### ۴.۱ قراردادهای بیمار و داده بالینی (۴۵ قرارداد)
RegisterPatient, UpdatePatientDemographics, CreateMedicalRecord, AppendProgressNote, RecordDiagnosis, RecordAllergy, GrantConsent, RevokeConsent, ShareDataWithProvider, QueryPatientHistory, ValidateConsentScope, AnonymizePatientData, MergeDuplicateRecords, ArchivePatientRecord, EmergencyBreakGlassAccess, RecordPatientPreference, LinkFamilyMember, RecordGenomicData, RecordMentalHealthNote, CreatePediatricRecord, UpdateImmunization, RecordAdvanceDirective, QueryConsentHistory, TransferPatientOwnership, FlagSensitiveData, RequestDataExport, ApproveDataExport, RecordSecondOpinion, LinkExternalRecord, ValidateIdentityMatch, SoftDeletePatient, RestorePatientRecord, GeneratePatientSummary, RecordLanguagePreference, SetDataSharingLevel, RecordFamilyHistory, UpdateEmergencyContact, RecordSocialDeterminants, CreateCarePlan, UpdateCarePlan, CloseCarePlan, RecordPatientFeedback, FlagHighRiskPatient, QueryActiveCarePlans, GenerateContinuityReport

### ۴.۲ قراردادهای تخت و ظرفیت فیزیکی (۳۵ قرارداد)
AllocateBed, ReleaseBed, ReserveBed, TransferBed, UpdateBedStatus, QueryAvailableBeds, PredictBedOccupancy, PrioritizeBedAllocation, BlockBedForMaintenance, RecordBedTurnover, SetBedPriorityRule, CalculateOccupancyRate, AllocateICUBed, AllocateNICUBed, ReserveOR, ReleaseOR, UpdateRoomStatus, AllocateAmbulance, TrackAmbulanceLocation, ReserveParking, ReleaseParking, AllocateIsolationRoom, RecordCleaningStatus, SetCapacityThreshold, QueryWardOccupancy, LockBedForTransfer, UnlockBed, CalculateTurnaroundTime, PublishBedCapacity, ReserveRemoteBed, ReleaseRemoteReservation, QueryNationalBedRegistry, UpdateBedType, RecordBedInfectionStatus, GenerateCapacityAlert

### ۴.۳ قراردادهای جراحی و اتاق عمل (۲۵ قرارداد)
ScheduleSurgery, CancelSurgery, RescheduleSurgery, AllocateOR, ReleaseOR, RecordSurgeryStart, RecordSurgeryEnd, AssignSurgicalTeam, CheckOREquipmentReadiness, LogSurgicalComplications, QueryORUtilization, RecordAnesthesiaDetails, PostOpTransfer, RecordImplantUsed, ValidateSurgicalConsent, UpdateSurgicalPriority, RecordBloodLoss, GenerateOperativeNote, RecordSurgeryDelay, AssignAnesthetist, RecordRecoveryStatus, LinkSurgeryToDiagnosis, QueryPendingSurgeries, UpdateOREquipmentList, GenerateSurgeryReport

### ۴.۴ قراردادهای تجهیزات و دستگاه (۳۰ قرارداد)
RegisterMedicalDevice, UpdateDeviceLocation, RecordCalibration, ScheduleMaintenance, ReportDeviceFailure, CheckoutDevice, ReturnDevice, TrackDeviceUsageHours, ValidateDeviceCertification, DecommissionDevice, QueryDeviceHistory, LinkDeviceToPatient, SetDeviceAlertThreshold, RecordSterilizationCycle, ValidateSterilization, TrackInstrumentSet, ReportMissingInstrument, AllocateMobileDevice, ReturnMobileDevice, RecordFirmwareUpdate, FlagDeviceRecall, QueryDeviceAvailability, RegisterNationalDevice, TransferDeviceOwnership, RecordDeviceImplant, VerifyDeviceAuthenticity, UpdateDeviceWarranty, SchedulePreventiveMaintenance, RecordDeviceDowntime, GenerateDeviceUtilizationReport

### ۴.۵ قراردادهای دارو، خون و انبار (۴۰ قرارداد)
ReceiveMedicationBatch, DispenseMedication, ReturnMedication, RecordMedicationAdministration, CheckDrugInteraction, TrackExpiryDate, QuarantineBatch, TransferStockBetweenWards, GenerateReorderAlert, AuditControlledSubstances, RecordTemperatureLog, ValidatePrescriptionMatch, ReceiveBloodUnit, IssueBloodUnit, ReturnBloodUnit, RecordTransfusion, TrackBloodExpiry, QuarantineBloodUnit, ReceiveConsumable, IssueConsumable, AdjustInventory, RecordWaste, ValidateColdChain, GenerateStockReport, RegisterDrugBatchNational, TransferDrugOwnership, DispenseNationalTrackedDrug, ReportAdverseDrugEvent, QuarantineNationalBatch, VerifyDrugAuthenticity, TrackMedicalDeviceNational, UpdateNationalPharmacyStock, RequestDrugResupply, ApproveDrugTransfer, RecordDrugRecall, GenerateNationalDrugReport, LinkPrescriptionToDispense, ValidateInsuranceDrugCoverage, RecordPatientDrugHistory, FlagDrugShortage

### ۴.۶ قراردادهای نیروی انسانی (۳۰ قرارداد)
RegisterStaff, AssignShift, RecordAttendance, RequestLeave, ApproveLeave, UpdateSkillCertificate, CalculateWorkloadScore, AssignOnCallDuty, ValidateStaffCompetency, RecordTrainingCompletion, TransferStaffTemporarily, QueryAvailableSpecialists, RecordPerformanceReview, SuspendStaffAccess, ReinstateStaffAccess, AssignMentor, RecordCME, UpdateLicenseStatus, CalculateOvertime, QueryStaffLocation, RegisterNationalStaffCredential, VerifyStaffLicense, SuspendNationalCredential, QueryStaffAvailabilityNational, RecordCrossFacilityDuty, UpdateSpecialty, RecordMalpracticeFlag, ApproveLocumTenens, GenerateStaffingReport, CalculateBurnoutRisk

### ۴.۷ قراردادهای پذیرش، تریاژ و جریان بیمار (۳۰ قرارداد)
AdmitPatient, DischargePatient, TransferPatient, CreateReferral, AcceptReferral, RecordTriageScore, UpdatePatientLocation, GenerateDischargeSummary, ScheduleFollowUp, CloseEpisodeOfCare, EscalateTriageLevel, RecordArrivalTime, RecordDepartureTime, CreateHomeCarePlan, AssignRehabilitation, RecordPalliativeDecision, UpdateCareLevel, LinkEpisodeToDiagnosis, GenerateTransferNote, ValidateDischargeCriteria, CreateNationalReferral, AcceptNationalReferral, RejectNationalReferral, TrackReferralStatus, CoordinatePatientTransfer, RecordTransferHandover, UpdateReceivingFacilityStatus, RecordMassCasualtyTriage, GenerateReferralAnalytics, FlagDelayedTransfer

### ۴.۸ قراردادهای مالی، بیمه و تأمین (۳۵ قرارداد)
GenerateInvoice, SubmitInsuranceClaim, ProcessClaimResponse, RecordPayment, AdjustBilling, AllocateCostToCenter, QueryOutstandingBalance, ValidateInsuranceEligibility, CreatePaymentPlan, ReconcilePayments, FlagFraudulentClaim, GenerateFinancialReport, CreatePurchaseOrder, ReceiveGoods, ApproveInvoice, RecordVendorPayment, UpdateBudget, AllocateBudget, AppealClaim, RecordCopay, GenerateCostReport, FlagHighCostCase, CheckNationalEligibility, SubmitNationalClaim, AdjudicateClaim, SettleClaimPayment, AppealNationalClaim, ReconcileFacilityPayments, FlagSuspiciousClaimPattern, RecordNationalPayment, GenerateNationalFinancialSummary, UpdateVendorContract, RecordProcurementApproval, TrackInvoiceStatus, CalculateFacilityRevenue

### ۴.۹ قراردادهای دسترسی، امنیت و انطباق (۳۰ قرارداد)
GrantRoleAccess, RevokeRoleAccess, LogAccessAttempt, BreakGlassAccess, ReviewAccessLog, UpdatePrivacyPreference, EnforceDataRetentionPolicy, DetectAnomalousAccess, IssueTemporaryCredential, RevokeAllSessions, RecordSecurityIncident, ApproveAccessRequest, SetRetentionPeriod, AnonymizeExpiredData, GenerateComplianceReport, RecordRegulatorySubmission, FlagPolicyViolation, ApproveBreakGlass, QueryAccessHistory, UpdateRoleDefinition, GrantNationalAccess, RevokeNationalAccess, LogNationalAccess, EnforceNationalPrivacy, GenerateNationalAuditReport, RecordCrossFacilityAccess, ValidatePurposeOfUse, FlagUnauthorizedAccess, UpdateNationalRole, GenerateAccessAnalytics

### ۴.۱۰ قراردادهای IoT، تله‌مدیسین و مانیتورینگ (۲۵ قرارداد)
RegisterIoTDevice, IngestVitalSign, RaiseCriticalAlert, AcknowledgeAlert, ConfigureAlertThreshold, AggregateSensorData, ValidateDeviceFirmware, LinkDeviceToPatient, QueryDeviceStream, ArchiveSensorData, SetPatientMonitoringProfile, DetectAbnormalPattern, StartTelemedicineSession, EndTelemedicineSession, RecordRemoteConsultation, ShareLiveVitals, ConfigureHomeMonitor, RaiseHomeAlert, RegisterNationalIoTDevice, StreamNationalVitals, CoordinateRemoteMonitoring, RecordTelemedicineOutcome, LinkDeviceToNationalID, GenerateMonitoringReport, FlagDeviceMalfunction

### ۴.۱۱ قراردادهای تحلیل، هوش مصنوعی و پژوهش (۲۰ قرارداد)
SubmitAnonymizedDataset, RegisterAIModel, ValidateModelVersion, RequestInterHospitalData, ApproveDataExchange, LogDataUsage, CalculateKPI, ShareBedCapacity, RequestEquipmentLoan, PublishCapacityForecast, AcceptCapacityOffer, RecordModelInference, FlagModelDrift, QuerySharedCapacity, SubmitAnonymizedNationalDataset, RegisterNationalAIModel, ValidateNationalModel, RequestResearchAccess, ApproveResearchDataset, LogResearchUsage

### ۴.۱۲ قراردادهای بازار منابع (۲۵ قرارداد)
OfferBedCapacity, OfferEquipmentTime, OfferLabCapacity, OfferStaffTime, OfferORSlot, OfferBloodUnit, AcceptResourceOffer, SettleResourceTrade, RecordResourcePayment, ValidateResourceOwnership, CancelResourceListing, RateResourceProvider, QueryMarketListings, LockResourceForTrade, ReleaseResourceLock, UpdateOfferPrice, ExpireOffer, GenerateMarketReport, OfferNationalBedCapacity, OfferNationalEquipment, OfferNationalLabSlot, OfferNationalStaff, AcceptNationalOffer, SettleNationalTrade, RateNationalProvider

### ۴.۱۳ قراردادهای بحران، اپیدمی و فوریت ملی (۲۰ قرارداد)
DeclareRegionalEmergency, ActivateCrisisProtocol, AllocateCrisisResources, TrackAmbulanceFleet, CoordinateMassCasualty, ReportOutbreakCase, ShareOutbreakData, RequestNationalSupport, DeclareNationalEmergency, ActivateNationalCrisisMode, AllocateNationalResources, TrackNationalAmbulance, CoordinateNationalResponse, ReportNationalOutbreak, UpdateOutbreakStatus, RequestMilitarySupport, ReleaseCrisisResources, GenerateCrisisReport, FlagResourceShortage, CoordinateVaccinationCampaign

---

## ۵. خلاصه مقیاس نهایی

| مورد              | تعداد تقریبی |
|-------------------|--------------|
| سازمان‌ها         | ۳۵           |
| کانال‌ها          | ۱۰۰          |
| قراردادهای هوشمند | بیش از ۳۵۰   |

---

## ۶. نکات پیاده‌سازی

- کانال‌های محلی برای هر مرکز خصوصی باقی می‌مانند.
- کانال‌های منطقه‌ای و ملی با سیاست‌های تأیید سخت‌گیرانه‌تر تعریف می‌شوند.
- از Private Data Collections برای داده‌های بسیار حساس استفاده شود.
- مدل قطعی (integer-based) برای محاسبات ظرفیت و اولویت حفظ شود.
- داشبورد ملی برای مشاهده ظرفیت، بحران و KPIها طراحی شود.
- بنچمارک با Tape و Caliper روی سناریوهای ملی اجرا شود.

---

## ۷. نتیجه‌گیری

این مستند نقشه راه کامل تبدیل پروژه فعلی Hyperledger Fabric به یک **شبکه ملی سلامت** را ارائه می‌دهد. با حفظ معماری اصلی پروژه (سازمان‌ها، کانال‌ها، قراردادهای Go، مدل قطعی و بازار منابع)، می‌توان سامانه‌ای مقیاس‌پذیر، قابل ممیزی و عملیاتی برای اتصال تمام مراکز درمانی کشور ایجاد کرد.

---

**پایان مستند**  
آماده استفاده به‌عنوان پایه پروپوزال، فصل معماری پایان‌نامه یا مستندات فنی پروژه.
