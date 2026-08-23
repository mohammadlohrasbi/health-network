#!/bin/bash
# نگاشت قرارداد ↔ کانال برای شبکه ملی سلامت — ۹۲ قرارداد در ۲۰ کانال
# این فایل توسط network.sh منبع (source) می‌شود — دقیقاً جای
# channel_contract_map.sh پروژه 6G را می‌گیرد و امضای یکسانی دارد.
#
# چرا ۲۰ کانال و نه ۱۰۰؟ به بخش «مقیاس» در README مراجعه کنید.
# خلاصه: ۱۰۰ کانال روی سرور ۳.۷ گیگابایتی اجرا نمی‌شود، و مهم‌تر
# اینکه بیشتر آن ۱۰۰ کانال جداسازی‌ای می‌سازند که با Private Data
# Collection ارزان‌تر و درست‌تر به دست می‌آید.

# ── ۲۰ کانال ──────────────────────────────────────────────
CHANNELS=(
  patientchannel clinicalchannel admissionchannel bedchannel
  surgerychannel equipmentchannel pharmacychannel bloodchannel
  labchannel imagingchannel staffchannel referralchannel
  emergencychannel insurancechannel supplychannel marketchannel
  consentchannel auditchannel compliancechannel analyticschannel
)

# ── نگاشت هر کانال به قراردادهایش ─────────────────────────
declare -A CHANNEL_CONTRACTS=(
  [patientchannel]="RegisterPatient UpdateDemographics LinkNationalIndex \
MergeDuplicateRecord DeactivatePatient QueryPatientSummary"

  [clinicalchannel]="RecordDiagnosis AppendProgressNote RecordVitalSigns \
RecordAllergy RecordProcedure RecordDischargeSummary CreateMedicalRecord"

  [admissionchannel]="RequestAdmission TriagePatient AssignPriority \
AdmitPatient TransferWard DischargePatient RecordEdArrival"

  [bedchannel]="AllocateBed ReleaseBed ReserveIcuBed ReportBedCensus \
RequestBedCapacity"

  [surgerychannel]="ScheduleSurgery ReserveOrSlot CancelSurgery \
RecordSurgicalOutcome RequestEmergencyOr"

  [equipmentchannel]="RegisterDevice ReserveDevice ReleaseDevice \
ReportDeviceFault LogDeviceMaintenance"

  [pharmacychannel]="PrescribeDrug DispenseDrug VerifyDrugSafety \
RegisterDrugBatch RecallDrugBatch ReturnDrug CheckDrugInteraction"

  [bloodchannel]="RegisterBloodUnit RequestBloodUnit IssueBloodUnit \
CrossMatchScreen ReturnBloodUnit ReportBloodInventory"

  [labchannel]="OrderLabTest RecordLabResult RequestLabCapacity \
FlagCriticalResult"

  [imagingchannel]="OrderImaging RecordImagingReport RequestImagingSlot"

  [staffchannel]="RegisterStaff AssignShift RequestOnCall \
RecordCredential RevokeCredential"

  [referralchannel]="CreateReferral AcceptReferral RejectReferral \
TransferPatient RequestSpecialistOpinion CloseReferral"

  [emergencychannel]="DispatchAmbulance AssignAmbulanceDestination \
ReportMassCasualty ActivateCrisisProtocol ReleaseAmbulance \
RequestPrehospitalDestination"

  [insurancechannel]="VerifyEligibility SubmitClaim AdjudicateClaim \
SettleClaim RejectClaim RecordCoveragePolicy"

  [supplychannel]="RegisterSupplyItem RecordShipment ReceiveShipment \
ReportStockLevel RequestRestock"

  [marketchannel]="MintResourceToken TransferToken BalanceOf \
ShareBedCapacity TradeOrSlot LendStaffHours"

  [consentchannel]="GrantConsent RevokeConsent CheckConsent \
ShareDataWithProvider LogDataAccess EmergencyOverrideAccess"

  [auditchannel]="LogPatientAudit LogClinicalAudit LogAccessAudit \
LogDrugAudit LogBloodAudit LogFinancialAudit LogSystemAudit"

  [compliancechannel]="RecordAccreditation ReportIncident \
RecordQualityIndicator VerifyProtocolAdherence"

  [analyticschannel]="ReportOccupancy ReportWaitTime \
ReportOutcomeIndicator ReportEpidemicSignal"
)

# ── طبقه‌بندی رفتاری قراردادها ─────────────────────────────
# این چیزی است که در پروژه 6G نبود و بعداً با analyse-deep.js
# مهندسی معکوس شد. اینجا از ابتدا صریح است، چون کاتالوگ بنچمارک
# و اسکریپت بذرکاری هر دو به آن نیاز دارند.
#
#   selector  قرارداد مرکز مقصد را خودش انتخاب می‌کند (x,y می‌گیرد،
#             تریاژ می‌کند، ممکن است رد کند). قرینه قراردادهای
#             مکانی 6G. نیازمند بذرکاری.
#   guarded   تصمیم قطعی می‌گیرد ولی مکان‌محور نیست — سازگاری خون،
#             ایمنی دارو، استحقاق بیمه. می‌تواند رد کند.
#   ledger    نوشتن کور. هیچ شرطی ندارد، هرگز رد نمی‌کند.
#             پایه تمیز برای سنجش «هزینه پیچیدگی chaincode».
#   market    عملیات توکن و بازار منابع.

declare -A CONTRACT_KIND=(
  [RequestAdmission]=selector      [TriagePatient]=selector
  [AdmitPatient]=selector          [RecordEdArrival]=selector
  [AllocateBed]=selector           [ReserveIcuBed]=selector
  [RequestBedCapacity]=selector    [RequestEmergencyOr]=selector
  [ScheduleSurgery]=selector       [ReserveOrSlot]=selector
  [ReserveDevice]=selector         [RequestLabCapacity]=selector
  [RequestImagingSlot]=selector    [CreateReferral]=selector
  [TransferPatient]=selector       [DispatchAmbulance]=selector
  [AssignAmbulanceDestination]=selector
  [RequestPrehospitalDestination]=selector
  [ReportMassCasualty]=selector    [RequestOnCall]=selector
  [RequestSpecialistOpinion]=selector
  [RequestRestock]=selector        [AssignPriority]=selector
  [TransferWard]=selector

  [VerifyDrugSafety]=guarded       [PrescribeDrug]=guarded
  [DispenseDrug]=guarded           [CheckDrugInteraction]=guarded
  [RequestBloodUnit]=guarded       [IssueBloodUnit]=guarded
  [CrossMatchScreen]=guarded       [VerifyEligibility]=guarded
  [SubmitClaim]=guarded            [AdjudicateClaim]=guarded
  [CheckConsent]=guarded           [ShareDataWithProvider]=guarded
  [EmergencyOverrideAccess]=guarded
  [RecallDrugBatch]=guarded        [FlagCriticalResult]=guarded

  [MintResourceToken]=market       [TransferToken]=market
  [BalanceOf]=market               [ShareBedCapacity]=market
  [TradeOrSlot]=market             [LendStaffHours]=market
)
# هر قراردادی که در CONTRACT_KIND نیامده باشد ledger است.

# ── سیاست تأیید ────────────────────────────────────────────
# مثل پروژه 6G پیش‌فرض OR است (یک امضا کافی). برای مطالعه
# منحنی گذردهی بر حسب تعداد امضا، این را به OutOf(3,...) و
# OutOf(5,...) تغییر دهید — همان آزمایشی که در 6G ماند و انجام نشد.
CC_POLICY="${CC_POLICY:-OR('org1MSP.member','org2MSP.member','org3MSP.member','org4MSP.member','org5MSP.member','org6MSP.member','org7MSP.member','org8MSP.member')}"

# ── نگاشت سازمان‌های منطقی به MSP های مستقر ───────────────
# مستند مخزن hospital سی‌وپنج سازمان تعریف می‌کند. اینجا هشت MSP
# مستقر می‌شود که هر کدام یک **دامنه اعتماد** است، و سازمان‌های
# منطقی با Organizational Unit داخل همان MSP از هم جدا می‌شوند.
# دلیل کامل در README، بخش «چرا ۸ MSP نه ۳۵».
declare -A ORG_ROLE=(
  [org1MSP]="وزارت بهداشت و نظام پزشکی — سیاست، اعتباربخشی، دسترسی اضطراری"
  [org2MSP]="سازمان‌های بیمه — استحقاق، مطالبه، تسویه"
  [org3MSP]="سازمان غذا و دارو — اصالت دارو، فراخوان، زنجیره تأمین"
  [org4MSP]="مرکز آمار و فناوری اطلاعات سلامت — شاخص ملی بیمار، تحلیل"
  [org5MSP]="فوریت‌های پزشکی ۱۱۵ — اعزام، انتقال، بحران"
  [org6MSP]="بیمارستان‌های دولتی و دانشگاهی (OU به ازای هر مرکز)"
  [org7MSP]="بیمارستان‌های خصوصی و درمانگاه‌ها (OU به ازای هر مرکز)"
  [org8MSP]="آزمایشگاه، داروخانه، تصویربرداری، انتقال خون (OU به ازای هر مرکز)"
)

# ── نام‌های قدیمی پروژه 6G ─────────────────────────────────
# نام کانال‌ها بین دو پروژه عوض شده، ولی دستورهای قدیمی در
# یادداشت‌ها و تاریخچه شل باقی می‌مانند و مدام کپی می‌شوند.
# به‌جای اینکه هر بار متوقف شود، نام قدیمی به معادل سلامتش
# ترجمه می‌شود و یک هشدار صریح چاپ می‌شود.
#
# معادل‌ها بر پایه **نقش** انتخاب شده‌اند نه شباهت نام:
# datachannel در 6G کانال پرچم‌دار قراردادهای مکانی بود؛ معادلش
# admissionchannel است که هر هفت قراردادش selector است.
declare -A LEGACY_CHANNEL=(
  [datachannel]=admissionchannel        # کانال پرچم‌دار selector
  [networkchannel]=analyticschannel
  [resourcechannel]=bedchannel          # تخصیص منابع کمیاب
  [performancechannel]=analyticschannel
  [iotchannel]=equipmentchannel         # دستگاه‌های متصل
  [authchannel]=consentchannel
  [accesschannel]=consentchannel
  [connectivitychannel]=referralchannel # برقراری پیوند بین دو طرف
  [sessionchannel]=admissionchannel
  [policychannel]=compliancechannel
  [securitychannel]=auditchannel
  [monitoringchannel]=analyticschannel
  [managementchannel]=staffchannel
  [optimizationchannel]=analyticschannel
  [faultchannel]=compliancechannel      # گزارش رخداد
  [trafficchannel]=analyticschannel
  [integrationchannel]=referralchannel
)

# resolve_channel <نام> → نام معتبر روی stdout، یا خالی اگر ناشناخته.
# پیام ترجمه به stderr می‌رود تا در جایگزینی فرمان قاطی نشود.
resolve_channel() {
  local want="$1" ch
  for ch in "${CHANNELS[@]}"; do
    [ "$ch" = "$want" ] && { printf '%s' "$want"; return 0; }
  done
  local mapped="${LEGACY_CHANNEL[$want]:-}"
  if [ -n "$mapped" ]; then
    echo "  ! «$want» نام پروژه 6G است — «$mapped» استفاده شد" >&2
    printf '%s' "$mapped"
    return 0
  fi
  return 1
}
