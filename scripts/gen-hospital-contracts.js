#!/usr/bin/env node
'use strict';

/* ═══════════════════════════════════════════════════════════════════════
   gen-hospital-contracts.js

   قرینه gen-spatial-contracts.js پروژه 6G، با یک تفاوت مهم در فلسفه.

   در 6G مجبور شدم ۸۶ قرارداد موجود را **بازنویسی** کنم، چون هیچ‌کدام
   عملیات شبکه انجام نمی‌دادند — Encrypt رمزگذاری نمی‌کرد، Authenticate
   اعتبارسنجی نمی‌کرد. اینجا از ابتدا هر قرارداد یکی از چهار نوع رفتاری
   است و آن رفتار در تولید کد تضمین می‌شود:

     selector  تریاژ می‌کند، مرکز مقصد را انتخاب می‌کند، و می‌تواند به سه
               دلیل مشخص رد کند (توانمندی، پنجره طلایی، اشباع).
     guarded   تصمیم قطعی بالینی/مالی می‌گیرد و می‌تواند رد کند.
     ledger    نوشتن کور، هرگز رد نمی‌کند. پایه شاهد بنچمارک.
     market    عملیات توکن.

   قید قطعیت مثل 6G برقرار است: هیچ float، هیچ math/rand، هیچ time.Now،
   هیچ پیمایش map. کل ریاضیات از clinical.go می‌آید.

   خروجی: scripts/generateChaincodes_hospital.sh
   ═══════════════════════════════════════════════════════════════════════ */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const CLINICAL_GO = fs.readFileSync(
  path.join(ROOT, 'reference', 'clinical.go'), 'utf8');

/* هسته بدون سرآیند package و بدون import — در shared.go تزریق
   می‌شود که import خودش را دارد. sim.go و آزمون‌ها وارد نمی‌شوند. */
const CLINICAL_BODY = CLINICAL_GO
  .slice(CLINICAL_GO.indexOf('const ('))
  .trim();

/* ── خواندن نگاشت کانال↔قرارداد از همان فایل bash ───────────────
   یک منبع حقیقت. اگر اینجا و آنجا دو لیست جدا داشتیم، همان اتفاقی
   می‌افتاد که در 6G با کاتالوگ بنچمارک افتاد و نیم روز طول کشید. */
function readMap() {
  const src = fs.readFileSync(
    path.join(__dirname, 'channel_contract_map.sh'), 'utf8');

  const chBlock = /CHANNELS=\(([\s\S]*?)\)/.exec(src)[1];
  const channels = chBlock.split(/\s+/).filter(Boolean);

  const map = {};
  const ccBlock = /declare -A CHANNEL_CONTRACTS=\(([\s\S]*?)\n\)/.exec(src)[1];
  const re = /\[(\w+)\]="([\s\S]*?)"/g;
  let m;
  while ((m = re.exec(ccBlock))) {
    map[m[1]] = m[2].replace(/\\\n/g, ' ').split(/\s+/).filter(Boolean);
  }

  const kind = {};
  const kBlock = /declare -A CONTRACT_KIND=\(([\s\S]*?)\n\)/.exec(src)[1];
  const kre = /\[(\w+)\]=(\w+)/g;
  while ((m = kre.exec(kBlock))) kind[m[1]] = m[2];

  return { channels, map, kind };
}

const { channels, map, kind } = readMap();

/* یک قرارداد ممکن است روی چند کانال باشد (مثل 6G که چند قرارداد
   مشترک داشت). کد یکی است؛ فقط استقرار تکرار می‌شود. */
const contracts = new Map();
for (const ch of channels) {
  for (const c of (map[ch] || [])) {
    if (!contracts.has(c)) contracts.set(c, { name: c, kind: kind[c] || 'ledger', channels: [] });
    contracts.get(c).channels.push(ch);
  }
}


/* ═════════════ مانیفست امضاها ═════════════

   در پروژه 6G فایل contract-fn-map.js با **مهندسی معکوس** از کد Go
   ساخته شد (analyse-contracts.js) — چون کد قراردادها دستی نوشته شده
   بود و منبع واحدی نداشت. آن مسیر شکننده است: هر تغییر امضا باید
   دوباره تحلیل می‌شد و اگر جا می‌ماند، بنچمارک آرگومان اشتباه
   می‌فرستاد و رد را به پای شبکه می‌نوشت.

   اینجا مولد **هم کد را می‌سازد و هم مانیفست را**. یک منبع حقیقت،
   و ناهمخوانی ساختاراً ممکن نیست.                                   */

const SIGNATURES = {
  selector: {
    params: ['id', 'patientCommit', 'x', 'y', 'rr', 'spo2', 'onOxygen',
             'sbp', 'hr', 'avpu', 'tempMilliC', 'flags', 'ageYears'],
    needsSeed: true,
    // Tape آرگومان ثابت می‌فرستد. کلید دفتر id است و هر فراخوانی id
    // یکسانی دارد → بازنویسی همان کلید. این برای Tape امن است (تعارض
    // MVCC نمی‌سازد چون خواندن-تغییر-نوشتن نیست) ولی فقط یک رکورد
    // واقعی می‌ماند. با TrackBeds=1 دیگر امن نیست.
    tapeSafe: true,
    note: 'تریاژ + انتخاب مرکز؛ سه دلیل رد. نرخ پذیرش خودش متریک است.',
  },
  ledger: {
    params: ['id', 'subject', 'detail'],
    needsSeed: true,   // commit() پیکربندی را می‌خواند
    tapeSafe: true,
    note: 'نوشتن کور، هرگز رد نمی‌کند. خط پایه شاهد.',
  },
  guarded: {
    params: ['id', 'subject', 'condition', 'threshold'],
    needsSeed: true,
    tapeSafe: true,
    note: 'تصمیم قطعی؛ می‌تواند رد کند.',
  },
  market: {
    params: ['id', 'from', 'to', 'amount', 'priceMicro'],
    needsSeed: true,
    tapeSafe: true,
    note: 'انتقال توکن.',
  },
};

// امضاهای اختصاصی — قراردادهایی که بدنه دست‌نویس دارند.
const SIG_OVERRIDE = {
  IssueBloodUnit: {
    params: ['id', 'unitID', 'recipientCommit', 'donorType', 'recipientType',
             'product', 'expirySec'],
    tapeSafe: true,
    note: 'غربال ABO/Rh + انقضا. ناسازگاری = رد.',
  },
  CrossMatchScreen: {
    params: ['id', 'donorType', 'recipientType', 'product'],
    tapeSafe: true,
    note: 'غربال سازگاری؛ ناسازگار = رد.',
  },
  VerifyDrugSafety: {
    params: ['id', 'drugCode', 'drugClassMask', 'allergyMask', 'weightGrams',
             'minPerKgMicro', 'maxPerKgMicro', 'orderedMicro', 'renalMilli',
             'expirySec'],
    tapeSafe: true,
    note: 'آلرژی + دوز + انقضا؛ هر تخلف = رد.',
  },
  AdjudicateClaim: {
    params: ['id', 'claimID', 'tariffMicro', 'coverageMilli',
             'deductibleMicro', 'remainingCapMicro'],
    tapeSafe: true,
    note: 'محاسبه سهم بیمه و بیمار.',
  },
  MintResourceToken: {
    params: ['owner', 'amount'],
    tapeSafe: true,
    note: 'ایجاد توکن روی یک حساب.',
  },
  ShareBedCapacity: {
    params: ['id', 'lender', 'borrower', 'facilityID', 'beds', 'priceMicro'],
    // اجاره‌دهنده باید واقعاً تخت آزاد داشته باشد و انتقال توکن
    // موجودی می‌خواهد. Tape با آرگومان ثابت بعد از چند فراخوانی
    // موجودی را تمام می‌کند — همان مشکل ShareBandwidth در 6G.
    tapeSafe: false,
    requires: 'فقط Caliper — Tape آرگومان ثابت می‌فرستد و موجودی حساب '
      + 'وام‌گیرنده پس از چند معامله تمام می‌شود',
    note: 'اجاره ظرفیت تخت؛ نیازمند تخت آزاد واقعی و موجودی.',
  },
  TransferToken: {
    params: ['from', 'to', 'amount'],
    // خواندن-تغییر-نوشتن روی دو حساب. Tape همان جفت حساب را تکرار
    // می‌کند → تعارض MVCC. و Tape آن را اشتباهاً کامیت‌شده می‌شمارد
    // چون اعتبارسنجی بعد از ترتیب‌دهی است و Tape آن مرحله را نمی‌بیند.
    tapeSafe: false,
    requires: 'فقط Caliper — دو حساب مشترک، Tape تعارض MVCC می‌سازد '
      + 'و آن را اشتباهاً موفق می‌شمارد',
    note: 'انتقال بین دو حساب.',
  },
  BalanceOf: { readOnly: true, params: ['owner'], note: 'فقط خواندن.' },
};

function signatureOf(c) {
  const base = SIGNATURES[c.kind];
  const ovr = SIG_OVERRIDE[c.name] || {};
  return {
    fn: c.name,
    kind: c.kind,
    channels: c.channels,
    params: ovr.params || base.params,
    needsSeed: ovr.needsSeed !== undefined ? ovr.needsSeed : base.needsSeed,
    tapeSafe: ovr.tapeSafe !== undefined ? ovr.tapeSafe : base.tapeSafe,
    readOnly: ovr.readOnly === true,
    requires: ovr.requires,
    note: ovr.note || base.note,
  };
}

/* ═════════════ shared.go — یک بار برای همه قراردادها ═════════════

   Go همه فایل‌های یک پوشه را یک package می‌بیند، پس نوع قرارداد
   HospitalBase را embed می‌کند و همه این متدها را می‌گیرد بدون
   اینکه کد ۹۲ بار تکرار شود.                                     */

const SHARED_GO = `package main

import (
    "encoding/json"
    "fmt"
    "strconv"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// HospitalBase هسته مشترک: پیکربندی، چیدمان مراکز، تریاژ، انتخاب
// مرکز، بازار و همه توابع قطعی clinical.go. هر قرارداد این را
// embed می‌کند.
type HospitalBase struct {
    contractapi.Contract
}

/* ── کلیدهای دفتر ─────────────────────────────────────────
   پیشوند ثابت تا فضای کلید هر نوع رکورد از بقیه جدا بماند و
   GetStateByRange بتواند فقط یک نوع را بخواند. */
const (
    keyConfig   = "config"
    prefixFac   = "facility~"
    prefixRec   = "record~"
    prefixAcct  = "account~"
    prefixToken = "token~"
)

// NetConfig پیکربندی سناریو. مثل SetPropagation/SetCapacity در 6G،
// اینها روی زنجیره‌اند تا همه peer ها یک پارامتر ببینند.
type NetConfig struct {
    Seed          string \`json:"seed"\`
    GridM         int64  \`json:"gridM"\`
    FacilityCount int64  \`json:"facilityCount"\`
    TrackBeds     int64  \`json:"trackBeds"\`     // ۰ خاموش — به توضیح زیر دقت کنید
    DetourMilli   int64  \`json:"detourMilli"\`
    DispatchSec   int64  \`json:"dispatchSec"\`
    Seeded        int64  \`json:"seeded"\`
}

// Record رکورد عمومی. هر قرارداد فیلدهای دامنه خودش را در Payload
// می‌گذارد؛ فیلدهای بالا برای کدی است که در همین فایل مشترک است.
// این همان ترفند GenericRecord در 6G است: encoding/json فیلدهای
// ناشناخته را نادیده می‌گیرد، پس Release می‌تواند اینجا زندگی کند
// و در ۹۲ قرارداد تکرار نشود.
type Record struct {
    ID         string \`json:"id"\`
    Contract   string \`json:"contract"\`
    Facility   string \`json:"facility"\`
    TriageLvl  int64  \`json:"triageLevel"\`
    News2      int64  \`json:"news2"\`
    Priority   int64  \`json:"priority"\`
    Reason     int64  \`json:"reason"\`
    TravelSec  int64  \`json:"travelSec"\`
    WaitSec    int64  \`json:"waitSec"\`
    Released   int64  \`json:"released"\`
    Timestamp  int64  \`json:"timestamp"\`
    Submitter  string \`json:"submitter"\`
    Payload    string \`json:"payload"\`
}

/* ── زمان قطعی ────────────────────────────────────────────
   time.Now() روی هر peer عدد متفاوتی می‌دهد و نتیجه تأیید را
   واگرا می‌کند. در 6G نود و سه مورد از این را باید عوض می‌کردم.
   اینجا هیچ قراردادی به time دسترسی ندارد چون shared.go تنها
   مسیر گرفتن زمان است. */
func (h *HospitalBase) txTime(ctx contractapi.TransactionContextInterface) int64 {
    ts, err := ctx.GetStub().GetTxTimestamp()
    if err != nil || ts == nil {
        return 0
    }
    return ts.Seconds
}

func (h *HospitalBase) submitter(ctx contractapi.TransactionContextInterface) string {
    id, err := ctx.GetClientIdentity().GetMSPID()
    if err != nil {
        return "unknown"
    }
    return id
}

/* ── پیکربندی ─────────────────────────────────────────── */

func (h *HospitalBase) SetConfig(ctx contractapi.TransactionContextInterface,
    seed string, gridM, facilityCount, trackBeds int64) error {

    if gridM <= 0 {
        return fmt.Errorf("اندازه شبکه باید مثبت باشد")
    }
    if facilityCount <= 0 || facilityCount > 500 {
        return fmt.Errorf("تعداد مرکز باید بین ۱ و ۵۰۰ باشد")
    }
    cfg := NetConfig{
        Seed: seed, GridM: gridM, FacilityCount: facilityCount,
        TrackBeds: trackBeds, DetourMilli: 1300, DispatchSec: 180,
    }
    b, _ := json.Marshal(cfg)
    return ctx.GetStub().PutState(keyConfig, b)
}

func (h *HospitalBase) getConfig(ctx contractapi.TransactionContextInterface) (NetConfig, error) {
    b, err := ctx.GetStub().GetState(keyConfig)
    if err != nil {
        return NetConfig{}, err
    }
    if b == nil {
        return NetConfig{}, fmt.Errorf("شبکه بذرکاری نشده: ابتدا SeedFacilityLayout را صدا بزنید")
    }
    var cfg NetConfig
    if err := json.Unmarshal(b, &cfg); err != nil {
        return NetConfig{}, err
    }
    return cfg, nil
}

/* ── بذرکاری چیدمان مراکز ─────────────────────────────────
   هر chaincode فضای حالت مستقل دارد، پس رجیستری مشترک ممکن
   نیست و هر قرارداد باید خودش بذرکاری شود. همین محدودیت در 6G
   بود و seed-network.sh را لازم کرد. */

func (h *HospitalBase) SeedFacilityLayout(ctx contractapi.TransactionContextInterface,
    seed string, gridM, facilityCount, trackBeds int64) error {

    if err := h.SetConfig(ctx, seed, gridM, facilityCount, trackBeds); err != nil {
        return err
    }
    facs := SeedFacilities(seed, facilityCount, gridM)
    for i := range facs {
        b, _ := json.Marshal(facs[i])
        if err := ctx.GetStub().PutState(prefixFac+facs[i].ID, b); err != nil {
            return err
        }
    }
    cfg, _ := h.getConfig(ctx)
    cfg.Seeded = 1
    cb, _ := json.Marshal(cfg)
    return ctx.GetStub().PutState(keyConfig, cb)
}

func (h *HospitalBase) loadFacilities(ctx contractapi.TransactionContextInterface,
    cfg NetConfig) ([]Facility, error) {

    out := make([]Facility, 0, cfg.FacilityCount)
    // پیمایش با اندیس صریح، نه GetStateByRange و نه map — ترتیب
    // باید روی هر peer یکسان باشد.
    for i := int64(1); i <= cfg.FacilityCount; i++ {
        id := "facility-" + strconv.FormatInt(i, 10)
        b, err := ctx.GetStub().GetState(prefixFac + id)
        if err != nil {
            return nil, err
        }
        if b == nil {
            continue
        }
        var f Facility
        if err := json.Unmarshal(b, &f); err != nil {
            return nil, err
        }
        out = append(out, f)
    }
    if len(out) == 0 {
        return nil, fmt.Errorf("هیچ مرکزی بذرکاری نشده")
    }
    return out, nil
}

/* ── هسته تصمیم: تریاژ و انتخاب مرکز ──────────────────────
   این تابع قلب قراردادهای selector است. قرینه دقیق تابعی که در
   6G RSSI هر آنتن را حساب می‌کرد، قوی‌ترین را برمی‌گزید و زیر
   آستانه SINR رد می‌کرد. */

func (h *HospitalBase) evaluate(ctx contractapi.TransactionContextInterface,
    patientID string, x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC,
    flags, ageYears int64) (Selection, News2Result, int64, error) {

    cfg, err := h.getConfig(ctx)
    if err != nil {
        return Selection{}, News2Result{}, 0, err
    }
    facs, err := h.loadFacilities(ctx, cfg)
    if err != nil {
        return Selection{}, News2Result{}, 0, err
    }

    news := News2(rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC)
    level, need := TriageLevel(news, flags, ageYears)
    window := GoldenWindowSec(level)

    sel := SelectFacility(x, y, facs, need, window, cfg.TrackBeds)
    return sel, news, level, nil
}

/* ── ثبت رکورد و حسابداری ظرفیت ────────────────────────────

   🔴 هشدار «کلید داغ» — درسی که در 6G گران تمام شد:

   اگر TrackBeds روشن باشد، هر تراکنش رکورد مرکز انتخاب‌شده را
   می‌خواند و بازمی‌نویسد. با ۱۲ مرکز و نرخ ۱۰۰ تراکنش بر ثانیه،
   دوازده کلید داغ داریم و تعارض MVCC نرخ موفقیت را نابود می‌کند
   (در 6G با ۸ آنتن به زیر ۴٪ افتاد).

   پیش‌فرض خاموش است. برای مطالعه کنترل پذیرش عمداً روشن کنید —
   آن‌وقت تعارض خودش یافته پژوهشی است نه اشکال پیاده‌سازی. */

func (h *HospitalBase) commit(ctx contractapi.TransactionContextInterface,
    id, contract string, sel Selection, news News2Result, level int64,
    payload string) error {

    cfg, err := h.getConfig(ctx)
    if err != nil {
        return err
    }
    now := h.txTime(ctx)

    rec := Record{
        ID: id, Contract: contract, Facility: sel.FacilityID,
        TriageLvl: level, News2: news.Total,
        Priority:  PriorityScore(level, news.Total, 0, 0),
        Reason:    sel.Reason, TravelSec: sel.TravelSec, WaitSec: sel.WaitSec,
        Timestamp: now, Submitter: h.submitter(ctx), Payload: payload,
    }
    b, _ := json.Marshal(rec)
    if err := ctx.GetStub().PutState(prefixRec+id, b); err != nil {
        return err
    }

    if cfg.TrackBeds != 0 && sel.Reason == AdmitOK && sel.FacilityID != "" {
        fb, err := ctx.GetStub().GetState(prefixFac + sel.FacilityID)
        if err != nil || fb == nil {
            return err
        }
        var f Facility
        if err := json.Unmarshal(fb, &f); err != nil {
            return err
        }
        f.UsedBeds++
        nb, _ := json.Marshal(f)
        if err := ctx.GetStub().PutState(prefixFac+f.ID, nb); err != nil {
            return err
        }
    }

    ctx.GetStub().SetEvent(contract, b)
    return nil
}

// Release ظرفیت اشغال‌شده را آزاد می‌کند. تنها تابع خواندن-تغییر-
// نوشتن روی رکورد است و برای Tape ناامن است (Tape آرگومان ثابت
// می‌فرستد → تعارض MVCC → و آن را اشتباهاً کامیت‌شده می‌شمارد،
// چون اعتبارسنجی بعد از ترتیب‌دهی است و Tape آن مرحله را نمی‌بیند).
func (h *HospitalBase) Release(ctx contractapi.TransactionContextInterface,
    id string) error {

    b, err := ctx.GetStub().GetState(prefixRec + id)
    if err != nil {
        return err
    }
    if b == nil {
        return fmt.Errorf("رکورد %s یافت نشد", id)
    }
    var rec Record
    if err := json.Unmarshal(b, &rec); err != nil {
        return err
    }
    if rec.Released != 0 {
        return fmt.Errorf("رکورد %s قبلاً آزاد شده", id)
    }
    rec.Released = 1
    nb, _ := json.Marshal(rec)
    if err := ctx.GetStub().PutState(prefixRec+id, nb); err != nil {
        return err
    }

    cfg, err := h.getConfig(ctx)
    if err == nil && cfg.TrackBeds != 0 && rec.Facility != "" {
        fb, err := ctx.GetStub().GetState(prefixFac + rec.Facility)
        if err == nil && fb != nil {
            var f Facility
            if json.Unmarshal(fb, &f) == nil && f.UsedBeds > 0 {
                f.UsedBeds--
                x, _ := json.Marshal(f)
                ctx.GetStub().PutState(prefixFac+f.ID, x)
            }
        }
    }
    return nil
}

/* ── پرس‌وجو ──────────────────────────────────────────── */

func (h *HospitalBase) QueryRecord(ctx contractapi.TransactionContextInterface,
    id string) (*Record, error) {

    b, err := ctx.GetStub().GetState(prefixRec + id)
    if err != nil {
        return nil, err
    }
    if b == nil {
        return nil, fmt.Errorf("رکورد %s یافت نشد", id)
    }
    var r Record
    if err := json.Unmarshal(b, &r); err != nil {
        return nil, err
    }
    return &r, nil
}

func (h *HospitalBase) QueryAllRecords(ctx contractapi.TransactionContextInterface) ([]*Record, error) {
    it, err := ctx.GetStub().GetStateByRange(prefixRec, prefixRec+"\\xff")
    if err != nil {
        return nil, err
    }
    defer it.Close()
    out := []*Record{}
    for it.HasNext() {
        kv, err := it.Next()
        if err != nil {
            return nil, err
        }
        var r Record
        if json.Unmarshal(kv.Value, &r) == nil {
            out = append(out, &r)
        }
    }
    return out, nil
}

func (h *HospitalBase) QueryFacility(ctx contractapi.TransactionContextInterface,
    id string) (*Facility, error) {

    b, err := ctx.GetStub().GetState(prefixFac + id)
    if err != nil {
        return nil, err
    }
    if b == nil {
        return nil, fmt.Errorf("مرکز %s یافت نشد", id)
    }
    var f Facility
    if err := json.Unmarshal(b, &f); err != nil {
        return nil, err
    }
    return &f, nil
}

func (h *HospitalBase) NetworkStatus(ctx contractapi.TransactionContextInterface) (string, error) {
    cfg, err := h.getConfig(ctx)
    if err != nil {
        return "", err
    }
    facs, err := h.loadFacilities(ctx, cfg)
    if err != nil {
        return "", err
    }
    var total, used int64
    for i := range facs {
        total += facs[i].TotalBeds
        used += facs[i].UsedBeds
    }
    return fmt.Sprintf("مراکز=%d تخت=%d اشغال=%d بذر=%s ردیابی=%d",
        len(facs), total, used, cfg.Seed, cfg.TrackBeds), nil
}

/* ── بازار منابع ──────────────────────────────────────────
   معیار پروژه 6G برای اینکه چه چیزی قابل معامله است حفظ شده:
   «منبعی قابل معامله است که هم قرارداد مالکیتش را تأیید کند و
   هم انتقالش رویدادی واقعی داشته باشد». تخت، اسلات اتاق عمل و
   ساعت کار متخصص هر سه این شرط را دارند. رضایت بیمار **ندارد** —
   ConsentToken در مستند اصلی به‌عنوان دارایی قابل انتقال آمده
   بود، ولی حق دسترسی به داده بیمار چیزی نیست که بین مراکز
   معامله شود. آن به consentchannel منتقل شد و قابل انتقال نیست. */

type Account struct {
    Owner   string \`json:"owner"\`
    Balance int64  \`json:"balance"\`
}

const initialBalance = int64(1000000)

func (h *HospitalBase) readAccount(ctx contractapi.TransactionContextInterface,
    owner string) (Account, error) {

    b, err := ctx.GetStub().GetState(prefixAcct + owner)
    if err != nil {
        return Account{}, err
    }
    if b == nil {
        // حساب بدون موجودی اولیه باعث شد در 6G هر معامله رد شود.
        return Account{Owner: owner, Balance: initialBalance}, nil
    }
    var a Account
    if err := json.Unmarshal(b, &a); err != nil {
        return Account{}, err
    }
    return a, nil
}

func (h *HospitalBase) writeAccount(ctx contractapi.TransactionContextInterface,
    a Account) error {
    b, _ := json.Marshal(a)
    return ctx.GetStub().PutState(prefixAcct+a.Owner, b)
}

func (h *HospitalBase) BalanceOf(ctx contractapi.TransactionContextInterface,
    owner string) (int64, error) {
    a, err := h.readAccount(ctx, owner)
    return a.Balance, err
}

func (h *HospitalBase) TransferToken(ctx contractapi.TransactionContextInterface,
    from, to string, amount int64) error {

    if amount <= 0 {
        return fmt.Errorf("مبلغ باید مثبت باشد")
    }
    if from == to {
        return fmt.Errorf("مبدأ و مقصد یکسان است")
    }
    fa, err := h.readAccount(ctx, from)
    if err != nil {
        return err
    }
    if fa.Balance < amount {
        return fmt.Errorf("موجودی ناکافی: %d < %d", fa.Balance, amount)
    }
    ta, err := h.readAccount(ctx, to)
    if err != nil {
        return err
    }
    fa.Balance -= amount
    ta.Balance += amount
    if err := h.writeAccount(ctx, fa); err != nil {
        return err
    }
    return h.writeAccount(ctx, ta)
}

${CLINICAL_BODY}
`;

/* ═════════════ chaincode.go — مختص هر قرارداد ═════════════ */

/* قالب selector: امضای کامل علائم حیاتی، تریاژ می‌کند، مرکز
   انتخاب می‌کند، و اگر رد شد **خطا برمی‌گرداند** — یعنی تراکنش
   کامیت نمی‌شود و در بنچمارک به‌عنوان رد شمرده می‌شود. این عمدی
   است: نرخ پذیرش خودش یک متریک است، همان‌طور که RelayFor در 6G
   با ۵۳.۴٪ پذیرش یافته پژوهشی بود نه اشکال. */
function selectorBody(name) {
  return `
// ${name} بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *${name}) ${name}(ctx contractapi.TransactionContextInterface,
    id, patientCommit string,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    if patientCommit == "" {
        return fmt.Errorf("تعهد شناسه بیمار الزامی است — شناسه خام روی زنجیره نرود")
    }
    if Scale2Required(0, 0, ageYears) {
        // مقیاس دوم اشباع اکسیژن لازم است؛ تصمیم خودکار مجاز نیست.
        // رکورد ثبت می‌شود ولی با پرچم ارجاع به انسان.
        return fmt.Errorf("این بیمار مقیاس دوم NEWS2 لازم دارد؛ تریاژ خودکار مجاز نیست")
    }

    sel, news, level, err := s.evaluate(ctx, patientCommit,
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return err
    }

    switch sel.Reason {
    case RejectCapability:
        return fmt.Errorf("هیچ مرکزی توانمندی لازم را ندارد (سطح تریاژ %d)", level)
    case RejectOutOfWindow:
        return fmt.Errorf("نزدیک‌ترین مرکز واجد شرایط خارج از پنجره %d ثانیه‌ای است",
            GoldenWindowSec(level))
    case RejectSaturated:
        return fmt.Errorf("همه مراکز واجد شرایط اشباع‌اند")
    case RejectNoCandidate:
        return fmt.Errorf("چیدمان مراکز بذرکاری نشده")
    }

    payload := fmt.Sprintf("{\\"commit\\":\\"%s\\",\\"x\\":%d,\\"y\\":%d,\\"news2\\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "${name}", sel, news, level, payload)
}

// Validate${name} ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *${name}) Validate${name}(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}`;
}

/* قالب guarded: تصمیم قطعی غیرمکانی. بدنه بر اساس نام قرارداد
   انتخاب می‌شود، چون هر کدام منطق دامنه متفاوتی دارد. */
const GUARDED = {
  IssueBloodUnit: `
// IssueBloodUnit سازگاری ABO/Rh و انقضا را بررسی و در صورت نبود
// سازگاری تراکنش را رد می‌کند.
//
// ⚠️ این یک غربال است نه جایگزین cross-match آزمایشگاهی. سیستم‌های
// Kell، Duffy و آنتی‌بادی‌های غیرمنتظره اینجا بررسی نمی‌شوند.
func (s *IssueBloodUnit) IssueBloodUnit(ctx contractapi.TransactionContextInterface,
    id, unitID, recipientCommit string,
    donorType, recipientType, product, expirySec int64) error {

    if !BloodCompatible(donorType, recipientType, product) {
        return fmt.Errorf("ناسازگاری ABO/Rh: دهنده %d به گیرنده %d برای فرآورده %d",
            donorType, recipientType, product)
    }
    now := s.txTime(ctx)
    switch ExpiryStatus(now, expirySec, 86400) {
    case 2:
        return fmt.Errorf("واحد %s منقضی شده", unitID)
    }
    payload := fmt.Sprintf(
        "{\\"unit\\":\\"%s\\",\\"donor\\":%d,\\"recipient\\":%d,\\"product\\":%d,\\"mask\\":%d}",
        unitID, donorType, recipientType, product,
        BloodDonorMask(recipientType, product))
    return s.commit(ctx, id, "IssueBloodUnit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

// ValidateIssueBloodUnit ماسک گروه‌های مجاز را بدون نوشتن برمی‌گرداند.
func (s *IssueBloodUnit) ValidateIssueBloodUnit(ctx contractapi.TransactionContextInterface,
    recipientType, product int64) (int64, error) {
    return BloodDonorMask(recipientType, product), nil
}`,

  CrossMatchScreen: `
// CrossMatchScreen غربال سازگاری پیش از cross-match کامل.
func (s *CrossMatchScreen) CrossMatchScreen(ctx contractapi.TransactionContextInterface,
    id string, donorType, recipientType, product int64) error {

    ok := BloodCompatible(donorType, recipientType, product)
    payload := fmt.Sprintf("{\\"donor\\":%d,\\"recipient\\":%d,\\"compatible\\":%t}",
        donorType, recipientType, ok)
    if !ok {
        return fmt.Errorf("غربال ناموفق: %s", payload)
    }
    return s.commit(ctx, id, "CrossMatchScreen", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}`,

  VerifyDrugSafety: `
// VerifyDrugSafety آلرژی، دوز و انقضا را با هم بررسی می‌کند و در
// هر تخلف تراکنش را رد می‌کند.
func (s *VerifyDrugSafety) VerifyDrugSafety(ctx contractapi.TransactionContextInterface,
    id, drugCode string,
    drugClassMask, allergyMask, weightGrams, minPerKgMicro, maxPerKgMicro,
    orderedMicro, renalMilli, expirySec int64) error {

    if AllergyConflict(drugClassMask, allergyMask) {
        return fmt.Errorf("تداخل آلرژی: کلاس دارو %d با آلرژی ثبت‌شده %d",
            drugClassMask, allergyMask)
    }
    if weightGrams <= 0 {
        return fmt.Errorf("وزن بیمار ثبت نشده؛ بررسی دوز ممکن نیست")
    }
    switch DoseCheck(weightGrams, minPerKgMicro, maxPerKgMicro, orderedMicro, renalMilli) {
    case -1:
        return fmt.Errorf("دوز کمتر از حد درمانی")
    case 1:
        return fmt.Errorf("دوز بیش از سقف مجاز (با تعدیل کلیوی %d)", renalMilli)
    }
    if ExpiryStatus(s.txTime(ctx), expirySec, 604800) == 2 {
        return fmt.Errorf("بچ دارو منقضی شده")
    }
    payload := fmt.Sprintf("{\\"drug\\":\\"%s\\",\\"dose\\":%d}", drugCode, orderedMicro)
    return s.commit(ctx, id, "VerifyDrugSafety", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}`,

  AdjudicateClaim: `
// AdjudicateClaim سهم بیمه و بیمار را حساب و ثبت می‌کند.
func (s *AdjudicateClaim) AdjudicateClaim(ctx contractapi.TransactionContextInterface,
    id, claimID string,
    tariffMicro, coverageMilli, deductibleMicro, remainingCapMicro int64) error {

    if tariffMicro <= 0 {
        return fmt.Errorf("تعرفه باید مثبت باشد")
    }
    r := ComputeClaim(tariffMicro, coverageMilli, deductibleMicro, remainingCapMicro)
    payload := fmt.Sprintf(
        "{\\"claim\\":\\"%s\\",\\"billed\\":%d,\\"covered\\":%d,\\"patient\\":%d,\\"capped\\":%d}",
        claimID, r.Billed, r.Covered, r.PatientPay, r.CappedBy)
    return s.commit(ctx, id, "AdjudicateClaim", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

// ValidateAdjudicateClaim محاسبه بدون نوشتن.
func (s *AdjudicateClaim) ValidateAdjudicateClaim(ctx contractapi.TransactionContextInterface,
    tariffMicro, coverageMilli, deductibleMicro, remainingCapMicro int64) (*ClaimResult, error) {
    r := ComputeClaim(tariffMicro, coverageMilli, deductibleMicro, remainingCapMicro)
    return &r, nil
}`,
};

/* بدنه پیش‌فرض guarded برای قراردادهایی که بدنه اختصاصی ندارند:
   یک بررسی شرط ساده که می‌تواند رد کند. */
function guardedDefault(name) {
  return `
// ${name} تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *${name}) ${name}(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\\"subject\\":\\"%s\\",\\"condition\\":%d,\\"threshold\\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "${name}", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}`;
}

/* قالب ledger: نوشتن کور. هرگز رد نمی‌کند. پایه شاهد بنچمارک —
   قرینه auditchannel در 6G که تمیزترین خط پایه بود. */
function ledgerBody(name) {
  return `
// ${name} ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *${name}) ${name}(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\\"subject\\":\\"%s\\",\\"detail\\":\\"%s\\"}", subject, detail)
    return s.commit(ctx, id, "${name}", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}`;
}

/* قالب market */
function marketBody(name) {
  const extra = {
    MintResourceToken: `
func (s *MintResourceToken) MintResourceToken(ctx contractapi.TransactionContextInterface,
    owner string, amount int64) error {
    if amount <= 0 {
        return fmt.Errorf("مقدار باید مثبت باشد")
    }
    a, err := s.readAccount(ctx, owner)
    if err != nil {
        return err
    }
    a.Balance += amount
    return s.writeAccount(ctx, a)
}`,
    ShareBedCapacity: `
// ShareBedCapacity اجاره ظرفیت تخت بین دو مرکز. معامله فقط وقتی
// انجام می‌شود که مرکز اجاره‌دهنده واقعاً تخت آزاد داشته باشد —
// همان معیار 6G: انتقال باید رویداد واقعی داشته باشد.
func (s *ShareBedCapacity) ShareBedCapacity(ctx contractapi.TransactionContextInterface,
    id, lender, borrower, facilityID string, beds, priceMicro int64) error {

    if beds <= 0 {
        return fmt.Errorf("تعداد تخت باید مثبت باشد")
    }
    f, err := s.QueryFacility(ctx, facilityID)
    if err != nil {
        return err
    }
    if f.TotalBeds-f.UsedBeds < beds {
        return fmt.Errorf("مرکز %s فقط %d تخت آزاد دارد", facilityID, f.TotalBeds-f.UsedBeds)
    }
    if err := s.TransferToken(ctx, borrower, lender, priceMicro*beds); err != nil {
        return err
    }
    payload := fmt.Sprintf("{\\"lender\\":\\"%s\\",\\"borrower\\":\\"%s\\",\\"beds\\":%d}",
        lender, borrower, beds)
    return s.commit(ctx, id, "ShareBedCapacity", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}`,
  };
  if (extra[name]) return extra[name];
  if (name === 'TransferToken' || name === 'BalanceOf') return ''; // در shared.go هست
  return `
func (s *${name}) ${name}(ctx contractapi.TransactionContextInterface,
    id, from, to string, amount, priceMicro int64) error {

    if amount <= 0 {
        return fmt.Errorf("مقدار باید مثبت باشد")
    }
    if err := s.TransferToken(ctx, to, from, priceMicro*amount); err != nil {
        return err
    }
    payload := fmt.Sprintf("{\\"from\\":\\"%s\\",\\"to\\":\\"%s\\",\\"amount\\":%d}",
        from, to, amount)
    return s.commit(ctx, id, "${name}", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}`;
}

function chaincodeGo(c) {
  let body;
  switch (c.kind) {
    case 'selector': body = selectorBody(c.name); break;
    case 'guarded':  body = GUARDED[c.name] || guardedDefault(c.name); break;
    case 'market':   body = marketBody(c.name); break;
    default:         body = ledgerBody(c.name);
  }
  return `package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ${c.name} — نوع رفتاری: ${c.kind}
// کانال‌ها: ${c.channels.join('، ')}
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ${c.name} struct {
    HospitalBase
}
${body}

func main() {
    cc, err := contractapi.NewChaincode(&${c.name}{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ${c.name}: %v\\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ${c.name}: %v\\n", err)
    }
}
`;
}

/* ═════════════ تولید اسکریپت bash ═════════════ */

const GO_MOD = `module %s

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
`;

function sh(s) { return s.replace(/\\/g, '\\\\').replace(/`/g, '\\`').replace(/\$/g, '\\$'); }

let out = `#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# generateChaincodes_hospital.sh — تولیدشده توسط
# scripts/gen-hospital-contracts.js. دستی ویرایش نکنید.
#
# ${contracts.size} قرارداد در ${channels.length} کانال.
# هر قرارداد دو فایل دارد: chaincode.go (مختص قرارداد) و
# shared.go (هسته مشترک + clinical.go).
#
# ⚡ مثل نسخه 6G، این اسکریپت **خودش کامپایل می‌کند** و اگر
# شکست بخورد exit 1 می‌دهد. علت: پنج بار پیاپی خطای کامپایل به
# شبکه رسید و deploy-staged.sh هر بار «موفق» اعلام کرد در حالی
# که هیچ قراردادی commit نشده بود.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

ROOT_DIR="\${ROOT_DIR:-/root/health-network}"
# 🔴 مسیر باید با زیرساخت بخواند، نه برعکس.
# deploy-staged.sh و network.sh هر دو
# CHAINCODE_DIR="$SCRIPTS_DIR/chaincode" دارند. نسخه اول این مولد
# در $ROOT_DIR/chaincode می‌نوشت، پس نصب با
# «directory not found: .../scripts/chaincode/RequestAdmission»
# شکست می‌خورد در حالی که هر ۱۱۰ قرارداد درست ساخته شده بودند.
CC_DIR="\${CC_DIR:-\$ROOT_DIR/scripts/chaincode}"
mkdir -p "\$CC_DIR"

# ── shared.go یک بار نوشته می‌شود و در هر پوشه کپی می‌شود ──
# نوشتن آن ۱۱۰ بار داخل اسکریپت، حجم را از ۱۵۰KB به ۴.۵MB می‌برد
# بدون اینکه حتی یک خط کد اضافه شود. همان اصلاحی که در 6G لازم شد.
SHARED_TMP="\$(mktemp -d)/shared.go"
cat > "\$SHARED_TMP" <<'HOSPSHAREDEOF'
${SHARED_GO}HOSPSHAREDEOF

log() { echo "[\$(date +'%H:%M:%S')] \$*"; }

`;

for (const c of contracts.values()) {
  const dir = `$CC_DIR/${c.name}`;
  out += `
# ── ${c.name} (${c.kind}) ──
log "تولید ${c.name}"
mkdir -p "${dir}"
cat > "${dir}/go.mod" <<'HOSPEOF'
${GO_MOD.replace('%s', c.name.toLowerCase())}HOSPEOF
cp "\$SHARED_TMP" "${dir}/shared.go"
cat > "${dir}/chaincode.go" <<'HOSPEOF'
${chaincodeGo(c)}HOSPEOF
`;
}

out += `
# ── حل وابستگی و کامپایل ──
#
# 🔴 درسی که فقط اجرای واقعی داد:
# «همه قراردادها یک shared.go دارند، پس اگر یکی کامپایل شود بقیه
# هم می‌شوند» برای **صحت کد** درست است — ولی هر پوشه ماژول Go
# مستقل خودش است و \`go build\` بدون \`go.sum\` در همان پوشه رد
# می‌کند:
#
#   missing go.sum entry for module providing package
#   github.com/hyperledger/fabric-contract-api-go/contractapi
#
# نسخه قبلی فقط اولی را tidy می‌کرد، پس ۱۰۹ پوشه دیگر go.sum
# نداشتند و در گام بسته‌بندی شکست می‌خوردند — بعد از اینکه شبکه
# کامل ساخته شده بود.
#
# راه‌حل: یک بار tidy، بعد همان go.sum به همه کپی شود. چون هر
# ۱۱۰ قرارداد **دقیقاً یک import** دارند، go.sum هر سه یکی است.
log "حل وابستگی‌ها (یک بار برای همه)"
FIRST=\$(find "\$CC_DIR" -mindepth 1 -maxdepth 1 -type d | sort | head -1)
cd "\$FIRST"
if ! go mod tidy; then
  log "خطا: go mod tidy در \$(basename "\$FIRST") شکست خورد"
  log "  بررسی کنید: دسترسی شبکه به proxy.golang.org و sum.golang.org"
  exit 1
fi
if [ ! -f go.sum ]; then
  log "خطا: go mod tidy موفق بود ولی go.sum نساخت"
  exit 1
fi

log "کامپایل \$(basename "\$FIRST") برای اعتبارسنجی"
if ! go build -o /dev/null . ; then
  log "خطا: کامپایل شکست خورد — استقرار متوقف شد"
  exit 1
fi

log "توزیع go.sum به بقیه قراردادها"
SUM="\$FIRST/go.sum"
COPIED=0
for d in "\$CC_DIR"/*/; do
  [ -d "\$d" ] || continue
  [ "\${d%/}" = "\$FIRST" ] && continue
  cp "\$SUM" "\${d}go.sum"
  COPIED=\$((COPIED+1))
done
log "go.sum در \$COPIED پوشه دیگر قرار گرفت"

# تأیید: هر پوشه باید go.mod و go.sum داشته باشد. بدون این
# بررسی، یک کپی ناموفق تا لحظه بسته‌بندی پنهان می‌ماند.
MISSING=0
for d in "\$CC_DIR"/*/; do
  [ -d "\$d" ] || continue
  { [ -f "\${d}go.mod" ] && [ -f "\${d}go.sum" ]; } || {
    log "خطا: \$(basename "\$d") فایل ماژول کامل ندارد"
    MISSING=\$((MISSING+1))
  }
done
[ "\$MISSING" -eq 0 ] || exit 1

# کامپایل آخرین قرارداد هم — اگر توزیع go.sum کار نکرده باشد،
# اینجا معلوم می‌شود نه در گام استقرار.
LAST=\$(find "\$CC_DIR" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
log "کامپایل \$(basename "\$LAST") برای تأیید توزیع"
cd "\$LAST"
if ! go build -o /dev/null . ; then
  log "خطا: کامپایل \$(basename "\$LAST") شکست خورد — توزیع go.sum ناقص است"
  exit 1
fi
# \${#} تعداد **پارامترهای موقعیتی** اسکریپت است، نه تعداد
# قراردادها — همیشه صفر. باید پوشه‌های واقعی شمرده شوند.
GENERATED=\$(find "\$CC_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
log "کامپایل موفق. \$GENERATED قرارداد آماده استقرار در \$CC_DIR"
if [ "\$GENERATED" -ne ${contracts.size} ]; then
  log "خطا: \$GENERATED پوشه ساخته شد، انتظار ${contracts.size}"
  exit 1
fi
`;

const target = path.join(__dirname, 'generateChaincodes_hospital.sh');
fs.writeFileSync(target, out, { mode: 0o755 });


/* ── مانیفست و نگاشت تابع ────────────────────────────────── */

const sigs = {};
for (const c of contracts.values()) sigs[c.name] = signatureOf(c);

fs.writeFileSync(path.join(__dirname, 'hospital-signatures.json'),
  JSON.stringify({
    generatedBy: 'gen-hospital-contracts.js',
    channels,
    channelContracts: map,
    contracts: sigs,
  }, null, 2));

/* contract-fn-map.js — جایگزین مستقیم فایل هم‌نام در server/ */
const fnLines = Object.keys(sigs).sort().map((n) => {
  const s = sigs[n];
  return `  ${n}: { fn: ${JSON.stringify(s.fn)}, params: ${JSON.stringify(s.params)}, `
       + `kind: ${JSON.stringify(s.kind)}, needsSeed: ${s.needsSeed}, `
       + `tapeSafe: ${s.tapeSafe}, readOnly: ${s.readOnly} },`;
}).join('\n');

fs.writeFileSync(path.join(ROOT, 'server', 'contract-fn-map.js'),
`'use strict';

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
${fnLines}
};

const CHANNEL_CHAINCODE_MAP = ${JSON.stringify(map, null, 2)};

const READ_ONLY_CONTRACTS = ${JSON.stringify(
  Object.keys(sigs).filter((n) => sigs[n].readOnly).sort())};

module.exports = { CONTRACT_FN, CHANNEL_CHAINCODE_MAP, READ_ONLY_CONTRACTS };
`);

/* آمار */
const byKind = {};
for (const c of contracts.values()) byKind[c.kind] = (byKind[c.kind] || 0) + 1;
console.log(`نوشته شد: ${target}`);
console.log(`  کانال‌ها      : ${channels.length}`);
console.log(`  قراردادها     : ${contracts.size}`);
for (const k of Object.keys(byKind).sort()) {
  console.log(`    ${k.padEnd(10)}: ${byKind[k]}`);
}
console.log(`  حجم اسکریپت  : ${(out.length / 1024).toFixed(0)} KB`);
