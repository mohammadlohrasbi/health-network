#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# generateChaincodes_hospital.sh — تولیدشده توسط
# scripts/gen-hospital-contracts.js. دستی ویرایش نکنید.
#
# 110 قرارداد در 20 کانال.
# هر قرارداد دو فایل دارد: chaincode.go (مختص قرارداد) و
# shared.go (هسته مشترک + clinical.go).
#
# ⚡ مثل نسخه 6G، این اسکریپت **خودش کامپایل می‌کند** و اگر
# شکست بخورد exit 1 می‌دهد. علت: پنج بار پیاپی خطای کامپایل به
# شبکه رسید و deploy-staged.sh هر بار «موفق» اعلام کرد در حالی
# که هیچ قراردادی commit نشده بود.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/root/health-network}"
CC_DIR="${CC_DIR:-$ROOT_DIR/chaincode}"
mkdir -p "$CC_DIR"

# ── shared.go یک بار نوشته می‌شود و در هر پوشه کپی می‌شود ──
# نوشتن آن ۱۱۰ بار داخل اسکریپت، حجم را از ۱۵۰KB به ۴.۵MB می‌برد
# بدون اینکه حتی یک خط کد اضافه شود. همان اصلاحی که در 6G لازم شد.
SHARED_TMP="$(mktemp -d)/shared.go"
cat > "$SHARED_TMP" <<'HOSPSHAREDEOF'
package main

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
    Seed          string `json:"seed"`
    GridM         int64  `json:"gridM"`
    FacilityCount int64  `json:"facilityCount"`
    TrackBeds     int64  `json:"trackBeds"`     // ۰ خاموش — به توضیح زیر دقت کنید
    DetourMilli   int64  `json:"detourMilli"`
    DispatchSec   int64  `json:"dispatchSec"`
    Seeded        int64  `json:"seeded"`
}

// Record رکورد عمومی. هر قرارداد فیلدهای دامنه خودش را در Payload
// می‌گذارد؛ فیلدهای بالا برای کدی است که در همین فایل مشترک است.
// این همان ترفند GenericRecord در 6G است: encoding/json فیلدهای
// ناشناخته را نادیده می‌گیرد، پس Release می‌تواند اینجا زندگی کند
// و در ۹۲ قرارداد تکرار نشود.
type Record struct {
    ID         string `json:"id"`
    Contract   string `json:"contract"`
    Facility   string `json:"facility"`
    TriageLvl  int64  `json:"triageLevel"`
    News2      int64  `json:"news2"`
    Priority   int64  `json:"priority"`
    Reason     int64  `json:"reason"`
    TravelSec  int64  `json:"travelSec"`
    WaitSec    int64  `json:"waitSec"`
    Released   int64  `json:"released"`
    Timestamp  int64  `json:"timestamp"`
    Submitter  string `json:"submitter"`
    Payload    string `json:"payload"`
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
    it, err := ctx.GetStub().GetStateByRange(prefixRec, prefixRec+"\xff")
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
    Owner   string `json:"owner"`
    Balance int64  `json:"balance"`
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

const (
	// آستانه‌های سطح‌بندی NEWS2 (بر پایه راهنمای RCP نسخه ۲)
	News2LowMax    = 4 // ۰–۴ کم‌خطر
	News2MediumMax = 6 // ۵–۶ خطر متوسط
	// ≥۷ پرخطر

	// سطح هوشیاری
	AvpuAlert    = 0
	AvpuVoice    = 1
	AvpuPain     = 2
	AvpuUnrespon = 3

	// گروه‌های خونی، به ترتیب ثابت. این ترتیب بخشی از قرارداد است و
	// نباید عوض شود — جدول‌های سازگاری بر پایه همین اندیس‌ها ساخته شده‌اند.
	BloodONeg  = 0
	BloodOPos  = 1
	BloodANeg  = 2
	BloodAPos  = 3
	BloodBNeg  = 4
	BloodBPos  = 5
	BloodABNeg = 6
	BloodABPos = 7

	// فرآورده خونی
	ProductRBC      = 0 // گلبول قرمز متراکم
	ProductPlasma   = 1 // پلاسما
	ProductPlatelet = 2 // پلاکت

	// توانمندی مراکز — بیت‌ماسک. هر مرکز مجموعه‌ای از این‌ها را دارد و
	// هر درخواست مجموعه‌ای را لازم دارد؛ مرکز واجد شرایط است اگر
	// required & ^capability == 0
	CapEmergency = 1 << 0 // اورژانس ۲۴ ساعته
	CapICU       = 1 << 1 // مراقبت ویژه بزرگسال
	CapNICU      = 1 << 2 // مراقبت ویژه نوزادان
	CapTrauma    = 1 << 3 // مرکز ترومای سطح یک
	CapCathLab   = 1 << 4 // آنژیوگرافی و کت‌لب
	CapStroke    = 1 << 5 // واحد سکته مغزی
	CapSurgery   = 1 << 6 // اتاق عمل فعال
	CapObstetric = 1 << 7 // زایمان
	CapDialysis  = 1 << 8 // دیالیز
	CapBurn      = 1 << 9 // سوختگی
	CapPediatric = 1 << 10
	CapOncology  = 1 << 11
	CapPsych     = 1 << 12
	CapImaging   = 1 << 13 // سی‌تی/ام‌آر‌آی
	CapLab       = 1 << 14
	CapBloodBank = 1 << 15
)

/* ═════════════════ ۱. توابع پایه صحیح ═════════════════ */

// floorDiv تقسیم با گرد کردن به سمت منفی بی‌نهایت.
// تقسیم صحیح در Go به سمت صفر گرد می‌کند، که برای مقادیر منفی
// (مثلاً اختلاف دما زیر صفر) نتیجه نامتقارن می‌دهد.
func floorDiv(a, b int64) int64 {
	q := a / b
	if (a%b != 0) && ((a < 0) != (b < 0)) {
		q--
	}
	return q
}

func absI(a int64) int64 {
	if a < 0 {
		return -a
	}
	return a
}

func minI(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func maxI(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// clampI مقدار را در بازه [lo, hi] محدود می‌کند.
func clampI(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Isqrt جذر صحیح با روش نیوتن. برای n<0 صفر برمی‌گرداند.
// بدون math.Sqrt، چون math.Sqrt روی float64 کار می‌کند.
func Isqrt(n int64) int64 {
	if n <= 0 {
		return 0
	}
	if n < 4 {
		return 1
	}
	x := n
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}

/* ═════════════════ ۲. هش قطعی با بهمن‌سازی ═════════════════

   درس گران‌قیمت پروژه 6G: FNV-1a تنها برای رشته‌هایی که فقط در
   کاراکتر آخر تفاوت دارند بد مخلوط می‌کند. در آنجا هش دو شناسه
   مجاور همبستگی ‑۰.۴۲ داشت و انحراف معیار سایه‌فرسایی به‌جای
   ۸dB می‌شد ۵.۵dB. اینجا هم شناسه‌ها دقیقاً همان شکل را دارند
   (patient-1, patient-2, …) پس همان مشکل تکرار می‌شد.
   راه‌حل: گام نهایی بهمن‌سازی Murmur3.                          */

func fnv1a(s string) uint32 {
	var h uint32 = 2166136261
	for i := 0; i < len(s); i++ {
		h ^= uint32(s[i])
		h *= 16777619
	}
	return h
}

// mix32 گام نهایی (finalizer) Murmur3. بیت‌های ورودی را در کل
// خروجی پخش می‌کند، طوری که تغییر یک بیت ورودی نیمی از بیت‌های
// خروجی را عوض کند.
func mix32(x uint32) uint32 {
	x ^= x >> 16
	x *= 0x85ebca6b
	x ^= x >> 13
	x *= 0xc2b2ae35
	x ^= x >> 16
	return x
}

// hashUniform عددی یکنواخت در [0, 1<<20) از ترکیب ورودی‌ها می‌سازد.
// جایگزین قطعی rand — همان ورودی همیشه همان خروجی، روی هر معماری.
func hashUniform(parts ...string) int64 {
	var h uint32 = 2166136261
	for _, p := range parts {
		h ^= fnv1a(p)
		h = mix32(h)
	}
	return int64(mix32(h) & 0xFFFFF)
}

// HashRange عددی قطعی در بازه [lo, hi] می‌سازد.
func HashRange(lo, hi int64, parts ...string) int64 {
	if hi <= lo {
		return lo
	}
	span := hi - lo + 1
	return lo + (hashUniform(parts...) % span)
}

/* ═════════════════ ۳. تعهد شناسه (حریم خصوصی) ═════════════════

   🔴 نکته‌ای که در مستندات مخزن hospital نبود و باید باشد:

   قرارداد RegisterPatient در آن مستند «شماره ملی» را ثبت می‌کند.
   دفتر کل فابریک **غیرقابل حذف** است. نوشتن شماره ملی روی زنجیره
   یعنی هر عضو کانال، برای همیشه، به شناسه ملی هر بیمار دسترسی دارد
   — و هیچ «حق فراموشی» قابل اعمال نیست. این نه فقط ریسک حریم
   خصوصی که در بیشتر چارچوب‌های حقوقی سلامت تخلف است.

   راه درست: روی زنجیره فقط **تعهد** (commitment) برود.
     CommitID(salt, nationalID) → یک اثر ۱۶ رقمی هگز
   نمک در پایگاه داده خارج‌زنجیره‌ای مرکز نگهداری می‌شود.
   کسی که هم نمک و هم شناسه را دارد می‌تواند تطابق را **اثبات** کند؛
   کسی که فقط زنجیره را دارد نمی‌تواند شناسه را **بازیابی** کند.

   برای داده بالینی حساس، لایه دوم لازم است: Private Data Collection
   (داده واقعی فقط روی peer های مجاز، هش آن روی زنجیره اصلی).
                                                                    */

const hexDigits = "0123456789abcdef"

// CommitID تعهد قطعی ۱۶ کاراکتری برای یک شناسه هویتی می‌سازد.
// هشدار: این یک تابع هش رمزنگارانه نیست و در برابر حمله فرهنگ‌واژه
// روی فضای کوچک (مثلاً شماره ملی ۱۰ رقمی) به‌تنهایی امن نیست —
// امنیت آن از محرمانه ماندن salt می‌آید. salt باید حداقل ۳۲ بایت
// تصادفی و مخصوص هر مرکز باشد.
func CommitID(salt, id string) string {
	var h1 uint32 = 2166136261
	h1 ^= fnv1a(salt)
	h1 = mix32(h1)
	h1 ^= fnv1a(id)
	h1 = mix32(h1)

	var h2 uint32 = 0x9e3779b9
	h2 ^= fnv1a(id + "|" + salt)
	h2 = mix32(h2)
	h2 ^= h1
	h2 = mix32(h2)

	out := make([]byte, 16)
	v := (uint64(h1) << 32) | uint64(h2)
	for i := 15; i >= 0; i-- {
		out[i] = hexDigits[v&0xF]
		v >>= 4
	}
	return string(out)
}

/* ═════════════════ ۴. NEWS2 — نمره هشدار زودهنگام ═════════════════

   National Early Warning Score 2، راهنمای Royal College of Physicians.
   عمداً یک سیستم امتیازدهی صحیح است — هیچ ممیز شناوری لازم ندارد،
   که آن را برای اجرای روی زنجیره ایده‌آل می‌کند.

   ⚠️ محدوده کاربرد: NEWS2 برای بزرگسالان ≥۱۶ سال است و برای
   بارداری و بیماران COPD مقیاس متفاوتی لازم دارد (مقیاس ۲ اشباع
   اکسیژن). این پیاده‌سازی مقیاس ۱ را حساب می‌کند و پرچم
   scaleTwoRequired را برمی‌گرداند تا قرارداد بتواند در آن موارد
   تصمیم خودکار نگیرد.                                            */

// News2Result نتیجه تفکیک‌شده امتیازدهی.
type News2Result struct {
	Total       int64 `json:"total"`       // ۰ تا ۲۰
	MaxSingle   int64 `json:"maxSingle"`   // بیشترین امتیاز یک پارامتر
	RiskBand    int64 `json:"riskBand"`    // ۰ کم، ۱ کم‌متوسط، ۲ متوسط، ۳ زیاد
	RespScore   int64 `json:"respScore"`
	SpO2Score   int64 `json:"spo2Score"`
	AirScore    int64 `json:"airScore"`
	SbpScore    int64 `json:"sbpScore"`
	PulseScore  int64 `json:"pulseScore"`
	AvpuScore   int64 `json:"avpuScore"`
	TempScore   int64 `json:"tempScore"`
}

func news2Resp(rr int64) int64 {
	switch {
	case rr <= 8:
		return 3
	case rr <= 11:
		return 1
	case rr <= 20:
		return 0
	case rr <= 24:
		return 2
	default:
		return 3
	}
}

func news2SpO2(spo2 int64) int64 {
	switch {
	case spo2 <= 91:
		return 3
	case spo2 <= 93:
		return 2
	case spo2 <= 95:
		return 1
	default:
		return 0
	}
}

func news2Sbp(sbp int64) int64 {
	switch {
	case sbp <= 90:
		return 3
	case sbp <= 100:
		return 2
	case sbp <= 110:
		return 1
	case sbp <= 219:
		return 0
	default:
		return 3
	}
}

func news2Pulse(hr int64) int64 {
	switch {
	case hr <= 40:
		return 3
	case hr <= 50:
		return 1
	case hr <= 90:
		return 0
	case hr <= 110:
		return 1
	case hr <= 130:
		return 2
	default:
		return 3
	}
}

// tempMilliC دما به میلی‌درجه سلسیوس: 36.5°C → 36500
func news2Temp(tempMilliC int64) int64 {
	switch {
	case tempMilliC <= 35000:
		return 3
	case tempMilliC <= 36000:
		return 1
	case tempMilliC <= 38000:
		return 0
	case tempMilliC <= 39000:
		return 1
	default:
		return 2
	}
}

// News2 امتیاز کامل را حساب می‌کند.
// onOxygen: صفر یعنی هوای اتاق، غیرصفر یعنی اکسیژن مکمل.
func News2(rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC int64) News2Result {
	r := News2Result{}
	r.RespScore = news2Resp(rr)
	r.SpO2Score = news2SpO2(spo2)
	if onOxygen != 0 {
		r.AirScore = 2
	}
	r.SbpScore = news2Sbp(sbp)
	r.PulseScore = news2Pulse(hr)
	if avpu != AvpuAlert {
		r.AvpuScore = 3
	}
	r.TempScore = news2Temp(tempMilliC)

	r.Total = r.RespScore + r.SpO2Score + r.AirScore +
		r.SbpScore + r.PulseScore + r.AvpuScore + r.TempScore

	r.MaxSingle = r.RespScore
	for _, s := range []int64{r.SpO2Score, r.AirScore, r.SbpScore,
		r.PulseScore, r.AvpuScore, r.TempScore} {
		if s > r.MaxSingle {
			r.MaxSingle = s
		}
	}

	// سطح‌بندی طبق راهنما: امتیاز ۳ در یک پارامتر منفرد حتی با
	// مجموع کم، پاسخ فوری لازم دارد.
	switch {
	case r.Total >= 7:
		r.RiskBand = 3
	case r.Total >= 5:
		r.RiskBand = 2
	case r.MaxSingle >= 3:
		r.RiskBand = 1
	default:
		r.RiskBand = 0
	}
	return r
}

// Scale2Required می‌گوید که آیا برای این بیمار باید مقیاس دوم
// اشباع اکسیژن استفاده شود — یعنی تصمیم خودکار مجاز نیست.
func Scale2Required(hasCopd, isPregnant, ageYears int64) bool {
	return hasCopd != 0 || isPregnant != 0 || ageYears < 16
}

/* ═════════════════ ۵. تریاژ ═════════════════

   سطح تریاژ ۱ (احیای فوری) تا ۵ (غیرفوری) — ساختار ESI.
   ورودی نمره NEWS2 به‌علاوه پرچم‌های خطر بالینی.               */

const (
	FlagAirway    = 1 << 0 // راه هوایی ناپایدار
	FlagCardiac   = 1 << 1 // درد قفسه سینه با تغییر ECG
	FlagStroke    = 1 << 2 // علائم سکته در پنجره درمانی
	FlagTrauma    = 1 << 3 // ترومای شدید
	FlagHemorrage = 1 << 4 // خونریزی فعال
	FlagSepsis    = 1 << 5 // شک به سپسیس
	FlagLabor     = 1 << 6 // زایمان فعال
	FlagBurn      = 1 << 7 // سوختگی وسیع
)

// TriageLevel سطح تریاژ ۱..۵ و ماسک توانمندی لازم را برمی‌گرداند.
func TriageLevel(news News2Result, flags, ageYears int64) (int64, int64) {
	need := int64(CapEmergency)
	level := int64(5)

	switch {
	case news.RiskBand >= 3 || news.AvpuScore >= 3:
		level = 1
	case news.RiskBand == 2 || news.MaxSingle >= 3:
		level = 2
	case news.Total >= 3:
		level = 3
	case news.Total >= 1:
		level = 4
	}

	// پرچم‌ها می‌توانند سطح را فقط **بالا** ببرند (عدد کمتر)،
	// هرگز پایین نیاورند. یک بیمار با علائم حیاتی طبیعی و سکته
	// در پنجره درمانی همچنان سطح ۱ است.
	if flags&FlagAirway != 0 {
		level = minI(level, 1)
		need |= CapICU
	}
	if flags&FlagCardiac != 0 {
		level = minI(level, 2)
		need |= CapCathLab | CapICU
	}
	if flags&FlagStroke != 0 {
		level = minI(level, 1)
		need |= CapStroke | CapImaging
	}
	if flags&FlagTrauma != 0 {
		level = minI(level, 1)
		need |= CapTrauma | CapSurgery
	}
	if flags&FlagHemorrage != 0 {
		level = minI(level, 2)
		need |= CapSurgery | CapBloodBank
	}
	if flags&FlagSepsis != 0 {
		level = minI(level, 2)
		need |= CapICU | CapLab
	}
	if flags&FlagLabor != 0 {
		level = minI(level, 2)
		need |= CapObstetric
	}
	if flags&FlagBurn != 0 {
		level = minI(level, 1)
		need |= CapBurn | CapICU
	}
	if ageYears < 16 {
		need |= CapPediatric
	}
	if ageYears < 1 {
		need |= CapNICU
	}
	return level, need
}

// GoldenWindowSec بیشینه زمان قابل‌قبول رسیدن به مرکز، بر حسب
// سطح تریاژ. قرینه مستقیم «آستانه SINR» در مدل رادیویی: زیر آن
// اتصال برقرار نمی‌شود، اینجا بالای آن ارجاع پذیرفته نمی‌شود.
func GoldenWindowSec(triageLevel int64) int64 {
	switch triageLevel {
	case 1:
		return 900 // ۱۵ دقیقه
	case 2:
		return 1800 // ۳۰ دقیقه
	case 3:
		return 3600 // ۱ ساعت
	case 4:
		return 7200
	default:
		return 14400
	}
}

/* ═════════════════ ۶. مکان و زمان سفر ═════════════════

   قرینه PlaceOnGrid/DistanceM در radio.go. تفاوت: در 6G هدف
   توان دریافتی بود، اینجا زمان رسیدن.                          */

// PlaceOnGrid مختصات قطعی یک موجودیت روی شبکه sizeM×sizeM.
func PlaceOnGrid(seed, id string, sizeM int64) (int64, int64) {
	if sizeM <= 0 {
		return 0, 0
	}
	x := HashRange(0, sizeM-1, seed, id, "x")
	y := HashRange(0, sizeM-1, seed, id, "y")
	return x, y
}

// DistanceM فاصله اقلیدسی صحیح بر حسب متر.
func DistanceM(x1, y1, x2, y2 int64) int64 {
	dx := x1 - x2
	dy := y1 - y2
	return Isqrt(dx*dx + dy*dy)
}

// RoadDistanceM فاصله جاده‌ای تقریبی. فاصله مستقیم هرگز فاصله
// واقعی رانندگی نیست؛ ضریب انحراف (detour index) در شبکه شهری
// معمولاً بین ۱.۲ و ۱.۴ است. detourMilli=1300 یعنی ۱.۳ برابر.
func RoadDistanceM(straightM, detourMilli int64) int64 {
	if detourMilli <= 0 {
		detourMilli = 1300
	}
	return floorDiv(straightM*detourMilli, 1000)
}

// TravelTimeSec زمان سفر بر حسب ثانیه.
//   speedKmh          سرعت پایه وسیله (آمبولانس شهری ~۴۵، بزرگراه ~۸۰)
//   congestionMilli   ضریب ترافیک: ۱۰۰۰ یعنی روان، ۲۵۰۰ یعنی ۲.۵ برابر کندتر
//   dispatchSec       تأخیر اعزام و بارگیری، مستقل از فاصله
func TravelTimeSec(roadM, speedKmh, congestionMilli, dispatchSec int64) int64 {
	if speedKmh <= 0 {
		speedKmh = 40
	}
	if congestionMilli <= 0 {
		congestionMilli = 1000
	}
	// متر بر ثانیه × ۱۰۰۰ برای حفظ دقت: km/h → m/s ضریب 1000/3600
	mmPerSec := floorDiv(speedKmh*1000*1000, 3600) // میلی‌متر بر ثانیه
	if mmPerSec <= 0 {
		return dispatchSec
	}
	// roadM متر است → میلی‌متر یعنی ×۱۰۰۰ (نه ×۱۰۰۰۰۰۰).
	// این ضریب اضافه اولین بار نتیجه را ۱۰۰۰ برابر کرد و هر ارجاعی
	// را «خارج از پنجره طلایی» نشان داد. آزمون تساوی آن را گرفت.
	base := floorDiv(roadM*1000, mmPerSec) // ثانیه
	return dispatchSec + floorDiv(base*congestionMilli, 1000)
}

/* ═════════════════ ۷. انتخاب مرکز ═════════════════

   این تابع قرینه دقیق انتخاب سلول سرویس‌دهنده در پروژه 6G است:

     6G                          سلامت
     ─────────────────────────   ────────────────────────────
     RSSI هر آنتن                زمان رسیدن به هر مرکز
     قوی‌ترین = سلول سرویس‌دهنده   سریع‌ترین واجدشرایط = مرکز مقصد
     SINR زیر آستانه → رد        زمان بیش از پنجره طلایی → رد
     سلول اشباع → رد             تخت آزاد ندارد → رد
     —                           توانمندی لازم را ندارد → رد

   یعنی سه علت رد داریم به‌جای دو تا، و علت سوم (تطابق توانمندی)
   چیزی است که در مدل رادیویی معادل ندارد. این خودش یک بُعد
   ارزیابی اضافه در بنچمارک است.                                */

// Facility یک مرکز درمانی نامزد.
type Facility struct {
	ID         string `json:"id"`
	X          int64  `json:"x"`
	Y          int64  `json:"y"`
	Capability int64  `json:"capability"` // بیت‌ماسک Cap*
	TotalBeds  int64  `json:"totalBeds"`
	UsedBeds   int64  `json:"usedBeds"`
	QueueLen   int64  `json:"queueLen"`   // بیماران در انتظار
	SpeedKmh   int64  `json:"speedKmh"`
	Congestion int64  `json:"congestion"` // میلی‌ضریب
}

// دلایل رد — عدد ثابت است تا در بنچمارک قابل شمارش باشد.
const (
	AdmitOK           = 0
	RejectNoCandidate = 1 // هیچ مرکزی تعریف نشده
	RejectCapability  = 2 // هیچ مرکزی توانمندی لازم را ندارد
	RejectOutOfWindow = 3 // نزدیک‌ترین واجد شرایط دیرتر از پنجره طلایی
	RejectSaturated   = 4 // همه واجدین شرایط پر هستند
)

// Selection نتیجه انتخاب مرکز.
type Selection struct {
	Reason      int64  `json:"reason"`
	FacilityID  string `json:"facilityId"`
	TravelSec   int64  `json:"travelSec"`
	RoadM       int64  `json:"roadM"`
	WaitSec     int64  `json:"waitSec"`
	TotalSec    int64  `json:"totalSec"`
	Considered  int64  `json:"considered"`  // چند مرکز بررسی شد
	Eligible    int64  `json:"eligible"`    // چند تا توانمندی داشتند
	WithinTime  int64  `json:"withinTime"`  // چند تا در پنجره بودند
	WithBed     int64  `json:"withBed"`     // چند تا تخت داشتند
}

// SelectFacility مرکز مقصد را انتخاب می‌کند.
//
//	patientX, patientY   محل بیمار
//	need                 ماسک توانمندی لازم (از TriageLevel)
//	windowSec            پنجره طلایی (از GoldenWindowSec)
//	trackBeds            صفر یعنی ظرفیت را نادیده بگیر
//
// ⚠️ نکته کلیدی درباره trackBeds — همان درس «کلید داغ» پروژه 6G:
// اگر ظرفیت را ردیابی کنیم، هر تراکنش باید رکورد مرکز انتخاب‌شده را
// بخواند و بازنویسد. با تعداد کم مرکز و نرخ بالای تراکنش، این یعنی
// تعارض MVCC انبوه (در 6G نرخ موفقیت با ۸ آنتن به زیر ۴٪ افتاد).
// پیش‌فرض خاموش است؛ برای مطالعه کنترل پذیرش عمداً روشن شود.
func SelectFacility(patientX, patientY int64, facs []Facility,
	need, windowSec, trackBeds int64) Selection {

	sel := Selection{Reason: RejectNoCandidate}
	sel.Considered = int64(len(facs))
	if len(facs) == 0 {
		return sel
	}

	best := -1
	var bestTotal int64
	anyEligible := false
	anyInWindow := false

	// پیمایش روی slice است نه map — ترتیب map در Go تصادفی است و
	// در صورت تساوی زمان، peer های مختلف مرکز متفاوتی می‌گزیدند.
	for i := range facs {
		f := facs[i]

		// ۱) تطابق توانمندی: هر بیت لازم باید موجود باشد.
		if need&^f.Capability != 0 {
			continue
		}
		anyEligible = true
		sel.Eligible++

		straight := DistanceM(patientX, patientY, f.X, f.Y)
		road := RoadDistanceM(straight, 1300)
		travel := TravelTimeSec(road, f.SpeedKmh, f.Congestion, 180)

		// ۲) پنجره زمانی
		if travel > windowSec {
			continue
		}
		anyInWindow = true
		sel.WithinTime++

		// ۳) ظرفیت
		if trackBeds != 0 {
			if f.TotalBeds > 0 && f.UsedBeds >= f.TotalBeds {
				continue
			}
		}
		sel.WithBed++

		wait := EstimatedWaitSec(f.QueueLen, f.TotalBeds, f.UsedBeds)
		total := travel + wait

		// انتخاب: کمترین زمان کل. در تساوی، شناسه کوچک‌تر برنده
		// است — بدون این قید، ترتیب ورودی نتیجه را عوض می‌کرد.
		if best < 0 || total < bestTotal ||
			(total == bestTotal && f.ID < facs[best].ID) {
			best = i
			bestTotal = total
			sel.FacilityID = f.ID
			sel.TravelSec = travel
			sel.RoadM = road
			sel.WaitSec = wait
			sel.TotalSec = total
		}
	}

	switch {
	case best >= 0:
		sel.Reason = AdmitOK
	case !anyEligible:
		sel.Reason = RejectCapability
		sel.FacilityID = ""
	case !anyInWindow:
		sel.Reason = RejectOutOfWindow
		sel.FacilityID = ""
	default:
		sel.Reason = RejectSaturated
		sel.FacilityID = ""
	}
	return sel
}

// EstimatedWaitSec تخمین انتظار با یک مدل صف ساده M/M/c.
// اشغال زیر ۸۰٪ عملاً بدون انتظار؛ بالای آن انتظار به‌سرعت رشد
// می‌کند. این رفتار غیرخطی همان چیزی است که در عمل دیده می‌شود.
func EstimatedWaitSec(queueLen, totalBeds, usedBeds int64) int64 {
	if totalBeds <= 0 {
		return int64(queueLen) * 600
	}
	free := totalBeds - usedBeds
	if free <= 0 {
		// همه پر: هر بیمار در صف منتظر یک ترخیص است.
		return (queueLen + 1) * 3600
	}
	occMilli := floorDiv(usedBeds*1000, totalBeds)
	if occMilli < 800 && queueLen < free {
		return 0
	}
	// ضریب تراکم: (اشغال/(۱-اشغال)) با محافظت از تقسیم بر صفر
	head := maxI(1000-occMilli, 50)
	factor := floorDiv(occMilli*1000, head)
	return floorDiv(queueLen*factor*60, 1000)
}

/* ═════════════════ ۸. سازگاری خونی ═════════════════

   جدول‌های واقعی سازگاری ABO/Rh. بیت i در ماسک یعنی گروه i
   می‌تواند به این گیرنده بدهد.

   ⚠️ این جدول‌ها ABO و Rh(D) را پوشش می‌دهند. تطابق واقعی
   پیش از تزریق نیاز به cross-match آزمایشگاهی دارد (آنتی‌بادی‌های
   غیرمنتظره، سیستم‌های Kell و Duffy و …). این تابع یک **غربال**
   است نه جایگزین cross-match. قرارداد باید نتیجه را
   «سازگار از نظر ABO/Rh» برچسب بزند، نه «قابل تزریق».         */

// گلبول قرمز: گیرنده نباید آنتی‌ژنی بگیرد که آنتی‌بادی‌اش را دارد.
var rbcCompatible = [8]int64{
	/* O-  */ 1 << BloodONeg,
	/* O+  */ 1<<BloodONeg | 1<<BloodOPos,
	/* A-  */ 1<<BloodONeg | 1<<BloodANeg,
	/* A+  */ 1<<BloodONeg | 1<<BloodOPos | 1<<BloodANeg | 1<<BloodAPos,
	/* B-  */ 1<<BloodONeg | 1<<BloodBNeg,
	/* B+  */ 1<<BloodONeg | 1<<BloodOPos | 1<<BloodBNeg | 1<<BloodBPos,
	/* AB- */ 1<<BloodONeg | 1<<BloodANeg | 1<<BloodBNeg | 1<<BloodABNeg,
	/* AB+ */ 0xFF,
}

// پلاسما: معکوس گلبول قرمز از نظر ABO — AB دهنده همگانی پلاسماست.
// Rh در پلاسما محدودیت ایجاد نمی‌کند (پلاسما گلبول ندارد).
var plasmaCompatible = [8]int64{
	/* O-  */ 0xFF,
	/* O+  */ 0xFF,
	/* A-  */ 1<<BloodANeg | 1<<BloodAPos | 1<<BloodABNeg | 1<<BloodABPos,
	/* A+  */ 1<<BloodANeg | 1<<BloodAPos | 1<<BloodABNeg | 1<<BloodABPos,
	/* B-  */ 1<<BloodBNeg | 1<<BloodBPos | 1<<BloodABNeg | 1<<BloodABPos,
	/* B+  */ 1<<BloodBNeg | 1<<BloodBPos | 1<<BloodABNeg | 1<<BloodABPos,
	/* AB- */ 1<<BloodABNeg | 1<<BloodABPos,
	/* AB+ */ 1<<BloodABNeg | 1<<BloodABPos,
}

// BloodCompatible می‌گوید آیا واحدی از گروه donor برای گیرنده
// recipient و فرآورده product از نظر ABO/Rh مجاز است.
func BloodCompatible(donor, recipient, product int64) bool {
	if donor < 0 || donor > 7 || recipient < 0 || recipient > 7 {
		return false
	}
	switch product {
	case ProductPlasma:
		return plasmaCompatible[recipient]&(1<<uint(donor)) != 0
	case ProductPlatelet:
		// پلاکت حجم پلاسمای قابل توجهی دارد؛ در عمل قانون پلاسما
		// اعمال می‌شود ولی در کمبود، ناهم‌گروه با شست‌وشو مجاز است.
		// اینجا سخت‌گیرانه قانون پلاسما را می‌گیریم.
		return plasmaCompatible[recipient]&(1<<uint(donor)) != 0
	default:
		return rbcCompatible[recipient]&(1<<uint(donor)) != 0
	}
}

// BloodDonorMask ماسک همه گروه‌های مجاز برای یک گیرنده.
func BloodDonorMask(recipient, product int64) int64 {
	if recipient < 0 || recipient > 7 {
		return 0
	}
	if product == ProductPlasma || product == ProductPlatelet {
		return plasmaCompatible[recipient]
	}
	return rbcCompatible[recipient]
}

/* ═════════════════ ۹. ایمنی دارو ═════════════════ */

// AllergyConflict برخورد کلاس دارویی با آلرژی ثبت‌شده بیمار.
func AllergyConflict(drugClassMask, patientAllergyMask int64) bool {
	return drugClassMask&patientAllergyMask != 0
}

// DoseCheck دوز تجویزشده را با محدوده مجاز مقایسه می‌کند.
//
//	weightGrams     وزن بیمار به گرم
//	minPerKgMicro   حداقل میکروگرم بر کیلوگرم
//	maxPerKgMicro   حداکثر میکروگرم بر کیلوگرم
//	orderedMicro    دوز تجویزشده به میکروگرم
//	renalMilli      تعدیل نارسایی کلیه: ۱۰۰۰ طبیعی، ۵۰۰ یعنی نصف سقف
//
// خروجی: ‑۱ کمتر از حد، ۰ در محدوده، ۱ بیش از حد
func DoseCheck(weightGrams, minPerKgMicro, maxPerKgMicro,
	orderedMicro, renalMilli int64) int64 {

	if weightGrams <= 0 {
		return 0 // بدون وزن نمی‌توان قضاوت کرد؛ قرارداد باید رد کند
	}
	if renalMilli <= 0 {
		renalMilli = 1000
	}
	lo := floorDiv(minPerKgMicro*weightGrams, 1000)
	hi := floorDiv(maxPerKgMicro*weightGrams, 1000)
	hi = floorDiv(hi*renalMilli, 1000)

	if orderedMicro < lo {
		return -1
	}
	if orderedMicro > hi {
		return 1
	}
	return 0
}

// InteractionSeverity شدت تداخل دو دارو، ۰ تا ۳.
// جدول واقعی تداخل هزاران جفت دارد و جای آن روی زنجیره نیست؛
// این تابع یک **مرجع نگاشتی** است: قرارداد شدت را از رکورد
// ثبت‌شده جدول تداخل می‌خواند، و این تابع فقط ترتیب متعارف
// جفت را می‌سازد تا کلید دفتر برای (A,B) و (B,A) یکی باشد.
func InteractionKey(drugA, drugB string) string {
	if drugA <= drugB {
		return drugA + "|" + drugB
	}
	return drugB + "|" + drugA
}

// ExpiryStatus وضعیت انقضای بچ دارو یا فرآورده خونی.
// nowSec و expirySec هر دو ثانیه یونیکس‌اند و now باید از
// txTimestamp(ctx) بیاید، نه time.Now().
// خروجی: ۰ معتبر، ۱ نزدیک انقضا (کمتر از هشدار)، ۲ منقضی
func ExpiryStatus(nowSec, expirySec, warnSec int64) int64 {
	if nowSec >= expirySec {
		return 2
	}
	if expirySec-nowSec <= warnSec {
		return 1
	}
	return 0
}

/* ═════════════════ ۱۰. بیمه و مالی ═════════════════

   همه مبالغ در میکرو‌واحد. با int64 سقف حدود ۹.۲×۱۰¹² واحد
   پول است که برای هر تعرفه واقعی کافی است.                    */

// ClaimResult تفکیک محاسبه مطالبه.
type ClaimResult struct {
	Billed      int64 `json:"billed"`      // مبلغ کل خدمت
	Deductible  int64 `json:"deductible"`  // فرانشیز کسرشده
	Covered     int64 `json:"covered"`     // سهم بیمه
	PatientPay  int64 `json:"patientPay"`  // سهم بیمار
	CappedBy    int64 `json:"cappedBy"`    // ۰ بدون سقف، ۱ سقف سالانه
}

// ComputeClaim سهم بیمه و بیمار را حساب می‌کند.
//
//	tariffMicro       تعرفه مصوب خدمت
//	coverageMilli     درصد پوشش در میلی‌درصد: ۷۰٪ → ۷۰۰۰۰
//	deductibleMicro   فرانشیز ثابت
//	remainingCapMicro باقیمانده سقف سالانه؛ منفی یعنی بدون سقف
func ComputeClaim(tariffMicro, coverageMilli, deductibleMicro,
	remainingCapMicro int64) ClaimResult {

	r := ClaimResult{Billed: tariffMicro}
	if tariffMicro <= 0 {
		return r
	}
	coverageMilli = clampI(coverageMilli, 0, 100000)

	base := tariffMicro - deductibleMicro
	if base < 0 {
		base = 0
	}
	r.Deductible = tariffMicro - base

	covered := floorDiv(base*coverageMilli, 100000)
	if remainingCapMicro >= 0 && covered > remainingCapMicro {
		covered = remainingCapMicro
		r.CappedBy = 1
	}
	r.Covered = covered
	r.PatientPay = tariffMicro - covered
	return r
}

/* ═════════════════ ۱۱. اولویت تخصیص منابع ═════════════════

   وقتی چند بیمار برای یک تخت ICU یا یک اسلات اتاق عمل رقابت
   می‌کنند، ترتیب باید قطعی و قابل توضیح باشد. عدد بزرگ‌تر یعنی
   اولویت بالاتر.

   ⚠️ هشدار طراحی: این تابع یک **ابزار پشتیبان تصمیم** است.
   تصمیم تخصیص منابع کمیاب درمانی مسئولیت بالینی و اخلاقی است و
   باید دست انسان بماند. قرارداد باید نمره را ثبت کند و تخصیص
   نهایی را به تأیید یک هویت با نقش پزشک مشروط کند — نه اینکه
   خودش خودکار تخصیص دهد. در سناریوی بحران این تمایز حیاتی است.  */

func PriorityScore(triageLevel, news2Total, waitedSec, ageYears int64) int64 {
	// سطح تریاژ وزن غالب دارد: هر سطح ۱۰۰۰۰ امتیاز
	score := (6 - clampI(triageLevel, 1, 5)) * 10000
	// نمره NEWS2 تا ۲۰ × ۲۰۰
	score += clampI(news2Total, 0, 20) * 200
	// انتظار: هر ۱۰ دقیقه ۵۰ امتیاز، سقف ۲۰۰۰ (تا ۶.۵ ساعت)
	score += minI(floorDiv(waitedSec, 600)*50, 2000)
	// سنین انتهایی طیف کمی وزن بیشتر
	if ageYears < 5 || ageYears >= 75 {
		score += 300
	}
	return score
}

/* ═════════════════ ۱۲. بذرکاری چیدمان مراکز ═════════════════

   قرینه SeedNetwork در پروژه 6G: هر قرارداد فضای حالت مستقل دارد،
   پس هر کدام باید چیدمان خودش را از همان بذر بسازد. با بذر یکسان،
   همه قراردادها همان نقشه را می‌بینند بدون اینکه رجیستری مشترکی
   لازم باشد.                                                       */

// SeedFacilities چیدمان قطعی n مرکز روی شبکه gridM×gridM.
func SeedFacilities(seed string, n, gridM int64) []Facility {
	caps := []int64{
		CapEmergency | CapICU | CapTrauma | CapSurgery | CapImaging | CapLab |
			CapBloodBank | CapCathLab | CapStroke | CapNICU | CapObstetric |
			CapPediatric | CapBurn | CapDialysis | CapOncology,
		CapEmergency | CapICU | CapSurgery | CapImaging | CapLab | CapBloodBank |
			CapObstetric | CapPediatric,
		CapEmergency | CapSurgery | CapImaging | CapLab | CapCathLab | CapICU,
		CapEmergency | CapImaging | CapLab | CapDialysis,
		CapEmergency | CapLab | CapPediatric | CapImaging,
	}
	out := make([]Facility, 0, n)
	for i := int64(1); i <= n; i++ {
		id := fmt.Sprintf("facility-%d", i)
		x, y := PlaceOnGrid(seed, id, gridM)
		out = append(out, Facility{
			ID:         id,
			X:          x,
			Y:          y,
			Capability: caps[int(i-1)%len(caps)],
			TotalBeds:  HashRange(30, 400, seed, id, "beds"),
			UsedBeds:   0,
			QueueLen:   0,
			SpeedKmh:   45,
			Congestion: HashRange(1000, 2200, seed, id, "cong"),
		})
	}
	return out
}
HOSPSHAREDEOF

log() { echo "[$(date +'%H:%M:%S')] $*"; }


# ── RegisterPatient (ledger) ──
log "تولید RegisterPatient"
mkdir -p "$CC_DIR/RegisterPatient"
cat > "$CC_DIR/RegisterPatient/go.mod" <<'HOSPEOF'
module registerpatient

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RegisterPatient/shared.go"
cat > "$CC_DIR/RegisterPatient/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RegisterPatient — نوع رفتاری: ledger
// کانال‌ها: patientchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RegisterPatient struct {
    HospitalBase
}

// RegisterPatient ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RegisterPatient) RegisterPatient(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RegisterPatient", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RegisterPatient{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RegisterPatient: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RegisterPatient: %v\n", err)
    }
}
HOSPEOF

# ── UpdateDemographics (ledger) ──
log "تولید UpdateDemographics"
mkdir -p "$CC_DIR/UpdateDemographics"
cat > "$CC_DIR/UpdateDemographics/go.mod" <<'HOSPEOF'
module updatedemographics

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/UpdateDemographics/shared.go"
cat > "$CC_DIR/UpdateDemographics/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// UpdateDemographics — نوع رفتاری: ledger
// کانال‌ها: patientchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type UpdateDemographics struct {
    HospitalBase
}

// UpdateDemographics ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *UpdateDemographics) UpdateDemographics(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "UpdateDemographics", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&UpdateDemographics{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode UpdateDemographics: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode UpdateDemographics: %v\n", err)
    }
}
HOSPEOF

# ── LinkNationalIndex (ledger) ──
log "تولید LinkNationalIndex"
mkdir -p "$CC_DIR/LinkNationalIndex"
cat > "$CC_DIR/LinkNationalIndex/go.mod" <<'HOSPEOF'
module linknationalindex

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LinkNationalIndex/shared.go"
cat > "$CC_DIR/LinkNationalIndex/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LinkNationalIndex — نوع رفتاری: ledger
// کانال‌ها: patientchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LinkNationalIndex struct {
    HospitalBase
}

// LinkNationalIndex ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LinkNationalIndex) LinkNationalIndex(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LinkNationalIndex", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LinkNationalIndex{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LinkNationalIndex: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LinkNationalIndex: %v\n", err)
    }
}
HOSPEOF

# ── MergeDuplicateRecord (ledger) ──
log "تولید MergeDuplicateRecord"
mkdir -p "$CC_DIR/MergeDuplicateRecord"
cat > "$CC_DIR/MergeDuplicateRecord/go.mod" <<'HOSPEOF'
module mergeduplicaterecord

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/MergeDuplicateRecord/shared.go"
cat > "$CC_DIR/MergeDuplicateRecord/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// MergeDuplicateRecord — نوع رفتاری: ledger
// کانال‌ها: patientchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type MergeDuplicateRecord struct {
    HospitalBase
}

// MergeDuplicateRecord ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *MergeDuplicateRecord) MergeDuplicateRecord(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "MergeDuplicateRecord", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&MergeDuplicateRecord{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode MergeDuplicateRecord: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode MergeDuplicateRecord: %v\n", err)
    }
}
HOSPEOF

# ── DeactivatePatient (ledger) ──
log "تولید DeactivatePatient"
mkdir -p "$CC_DIR/DeactivatePatient"
cat > "$CC_DIR/DeactivatePatient/go.mod" <<'HOSPEOF'
module deactivatepatient

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/DeactivatePatient/shared.go"
cat > "$CC_DIR/DeactivatePatient/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// DeactivatePatient — نوع رفتاری: ledger
// کانال‌ها: patientchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type DeactivatePatient struct {
    HospitalBase
}

// DeactivatePatient ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *DeactivatePatient) DeactivatePatient(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "DeactivatePatient", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&DeactivatePatient{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode DeactivatePatient: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode DeactivatePatient: %v\n", err)
    }
}
HOSPEOF

# ── QueryPatientSummary (ledger) ──
log "تولید QueryPatientSummary"
mkdir -p "$CC_DIR/QueryPatientSummary"
cat > "$CC_DIR/QueryPatientSummary/go.mod" <<'HOSPEOF'
module querypatientsummary

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/QueryPatientSummary/shared.go"
cat > "$CC_DIR/QueryPatientSummary/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// QueryPatientSummary — نوع رفتاری: ledger
// کانال‌ها: patientchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type QueryPatientSummary struct {
    HospitalBase
}

// QueryPatientSummary ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *QueryPatientSummary) QueryPatientSummary(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "QueryPatientSummary", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&QueryPatientSummary{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode QueryPatientSummary: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode QueryPatientSummary: %v\n", err)
    }
}
HOSPEOF

# ── RecordDiagnosis (ledger) ──
log "تولید RecordDiagnosis"
mkdir -p "$CC_DIR/RecordDiagnosis"
cat > "$CC_DIR/RecordDiagnosis/go.mod" <<'HOSPEOF'
module recorddiagnosis

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordDiagnosis/shared.go"
cat > "$CC_DIR/RecordDiagnosis/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordDiagnosis — نوع رفتاری: ledger
// کانال‌ها: clinicalchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordDiagnosis struct {
    HospitalBase
}

// RecordDiagnosis ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordDiagnosis) RecordDiagnosis(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordDiagnosis", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordDiagnosis{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordDiagnosis: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordDiagnosis: %v\n", err)
    }
}
HOSPEOF

# ── AppendProgressNote (ledger) ──
log "تولید AppendProgressNote"
mkdir -p "$CC_DIR/AppendProgressNote"
cat > "$CC_DIR/AppendProgressNote/go.mod" <<'HOSPEOF'
module appendprogressnote

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/AppendProgressNote/shared.go"
cat > "$CC_DIR/AppendProgressNote/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AppendProgressNote — نوع رفتاری: ledger
// کانال‌ها: clinicalchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type AppendProgressNote struct {
    HospitalBase
}

// AppendProgressNote ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *AppendProgressNote) AppendProgressNote(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "AppendProgressNote", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&AppendProgressNote{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode AppendProgressNote: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode AppendProgressNote: %v\n", err)
    }
}
HOSPEOF

# ── RecordVitalSigns (ledger) ──
log "تولید RecordVitalSigns"
mkdir -p "$CC_DIR/RecordVitalSigns"
cat > "$CC_DIR/RecordVitalSigns/go.mod" <<'HOSPEOF'
module recordvitalsigns

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordVitalSigns/shared.go"
cat > "$CC_DIR/RecordVitalSigns/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordVitalSigns — نوع رفتاری: ledger
// کانال‌ها: clinicalchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordVitalSigns struct {
    HospitalBase
}

// RecordVitalSigns ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordVitalSigns) RecordVitalSigns(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordVitalSigns", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordVitalSigns{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordVitalSigns: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordVitalSigns: %v\n", err)
    }
}
HOSPEOF

# ── RecordAllergy (ledger) ──
log "تولید RecordAllergy"
mkdir -p "$CC_DIR/RecordAllergy"
cat > "$CC_DIR/RecordAllergy/go.mod" <<'HOSPEOF'
module recordallergy

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordAllergy/shared.go"
cat > "$CC_DIR/RecordAllergy/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordAllergy — نوع رفتاری: ledger
// کانال‌ها: clinicalchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordAllergy struct {
    HospitalBase
}

// RecordAllergy ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordAllergy) RecordAllergy(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordAllergy", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordAllergy{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordAllergy: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordAllergy: %v\n", err)
    }
}
HOSPEOF

# ── RecordProcedure (ledger) ──
log "تولید RecordProcedure"
mkdir -p "$CC_DIR/RecordProcedure"
cat > "$CC_DIR/RecordProcedure/go.mod" <<'HOSPEOF'
module recordprocedure

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordProcedure/shared.go"
cat > "$CC_DIR/RecordProcedure/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordProcedure — نوع رفتاری: ledger
// کانال‌ها: clinicalchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordProcedure struct {
    HospitalBase
}

// RecordProcedure ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordProcedure) RecordProcedure(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordProcedure", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordProcedure{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordProcedure: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordProcedure: %v\n", err)
    }
}
HOSPEOF

# ── RecordDischargeSummary (ledger) ──
log "تولید RecordDischargeSummary"
mkdir -p "$CC_DIR/RecordDischargeSummary"
cat > "$CC_DIR/RecordDischargeSummary/go.mod" <<'HOSPEOF'
module recorddischargesummary

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordDischargeSummary/shared.go"
cat > "$CC_DIR/RecordDischargeSummary/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordDischargeSummary — نوع رفتاری: ledger
// کانال‌ها: clinicalchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordDischargeSummary struct {
    HospitalBase
}

// RecordDischargeSummary ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordDischargeSummary) RecordDischargeSummary(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordDischargeSummary", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordDischargeSummary{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordDischargeSummary: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordDischargeSummary: %v\n", err)
    }
}
HOSPEOF

# ── CreateMedicalRecord (ledger) ──
log "تولید CreateMedicalRecord"
mkdir -p "$CC_DIR/CreateMedicalRecord"
cat > "$CC_DIR/CreateMedicalRecord/go.mod" <<'HOSPEOF'
module createmedicalrecord

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/CreateMedicalRecord/shared.go"
cat > "$CC_DIR/CreateMedicalRecord/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// CreateMedicalRecord — نوع رفتاری: ledger
// کانال‌ها: clinicalchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type CreateMedicalRecord struct {
    HospitalBase
}

// CreateMedicalRecord ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *CreateMedicalRecord) CreateMedicalRecord(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "CreateMedicalRecord", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&CreateMedicalRecord{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode CreateMedicalRecord: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode CreateMedicalRecord: %v\n", err)
    }
}
HOSPEOF

# ── RequestAdmission (selector) ──
log "تولید RequestAdmission"
mkdir -p "$CC_DIR/RequestAdmission"
cat > "$CC_DIR/RequestAdmission/go.mod" <<'HOSPEOF'
module requestadmission

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestAdmission/shared.go"
cat > "$CC_DIR/RequestAdmission/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestAdmission — نوع رفتاری: selector
// کانال‌ها: admissionchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestAdmission struct {
    HospitalBase
}

// RequestAdmission بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestAdmission) RequestAdmission(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestAdmission", sel, news, level, payload)
}

// ValidateRequestAdmission ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestAdmission) ValidateRequestAdmission(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestAdmission{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestAdmission: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestAdmission: %v\n", err)
    }
}
HOSPEOF

# ── TriagePatient (selector) ──
log "تولید TriagePatient"
mkdir -p "$CC_DIR/TriagePatient"
cat > "$CC_DIR/TriagePatient/go.mod" <<'HOSPEOF'
module triagepatient

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/TriagePatient/shared.go"
cat > "$CC_DIR/TriagePatient/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// TriagePatient — نوع رفتاری: selector
// کانال‌ها: admissionchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type TriagePatient struct {
    HospitalBase
}

// TriagePatient بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *TriagePatient) TriagePatient(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "TriagePatient", sel, news, level, payload)
}

// ValidateTriagePatient ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *TriagePatient) ValidateTriagePatient(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&TriagePatient{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode TriagePatient: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode TriagePatient: %v\n", err)
    }
}
HOSPEOF

# ── AssignPriority (selector) ──
log "تولید AssignPriority"
mkdir -p "$CC_DIR/AssignPriority"
cat > "$CC_DIR/AssignPriority/go.mod" <<'HOSPEOF'
module assignpriority

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/AssignPriority/shared.go"
cat > "$CC_DIR/AssignPriority/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AssignPriority — نوع رفتاری: selector
// کانال‌ها: admissionchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type AssignPriority struct {
    HospitalBase
}

// AssignPriority بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *AssignPriority) AssignPriority(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "AssignPriority", sel, news, level, payload)
}

// ValidateAssignPriority ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *AssignPriority) ValidateAssignPriority(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&AssignPriority{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode AssignPriority: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode AssignPriority: %v\n", err)
    }
}
HOSPEOF

# ── AdmitPatient (selector) ──
log "تولید AdmitPatient"
mkdir -p "$CC_DIR/AdmitPatient"
cat > "$CC_DIR/AdmitPatient/go.mod" <<'HOSPEOF'
module admitpatient

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/AdmitPatient/shared.go"
cat > "$CC_DIR/AdmitPatient/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AdmitPatient — نوع رفتاری: selector
// کانال‌ها: admissionchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type AdmitPatient struct {
    HospitalBase
}

// AdmitPatient بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *AdmitPatient) AdmitPatient(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "AdmitPatient", sel, news, level, payload)
}

// ValidateAdmitPatient ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *AdmitPatient) ValidateAdmitPatient(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&AdmitPatient{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode AdmitPatient: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode AdmitPatient: %v\n", err)
    }
}
HOSPEOF

# ── TransferWard (selector) ──
log "تولید TransferWard"
mkdir -p "$CC_DIR/TransferWard"
cat > "$CC_DIR/TransferWard/go.mod" <<'HOSPEOF'
module transferward

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/TransferWard/shared.go"
cat > "$CC_DIR/TransferWard/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// TransferWard — نوع رفتاری: selector
// کانال‌ها: admissionchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type TransferWard struct {
    HospitalBase
}

// TransferWard بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *TransferWard) TransferWard(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "TransferWard", sel, news, level, payload)
}

// ValidateTransferWard ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *TransferWard) ValidateTransferWard(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&TransferWard{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode TransferWard: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode TransferWard: %v\n", err)
    }
}
HOSPEOF

# ── DischargePatient (ledger) ──
log "تولید DischargePatient"
mkdir -p "$CC_DIR/DischargePatient"
cat > "$CC_DIR/DischargePatient/go.mod" <<'HOSPEOF'
module dischargepatient

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/DischargePatient/shared.go"
cat > "$CC_DIR/DischargePatient/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// DischargePatient — نوع رفتاری: ledger
// کانال‌ها: admissionchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type DischargePatient struct {
    HospitalBase
}

// DischargePatient ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *DischargePatient) DischargePatient(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "DischargePatient", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&DischargePatient{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode DischargePatient: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode DischargePatient: %v\n", err)
    }
}
HOSPEOF

# ── RecordEdArrival (selector) ──
log "تولید RecordEdArrival"
mkdir -p "$CC_DIR/RecordEdArrival"
cat > "$CC_DIR/RecordEdArrival/go.mod" <<'HOSPEOF'
module recordedarrival

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordEdArrival/shared.go"
cat > "$CC_DIR/RecordEdArrival/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordEdArrival — نوع رفتاری: selector
// کانال‌ها: admissionchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordEdArrival struct {
    HospitalBase
}

// RecordEdArrival بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RecordEdArrival) RecordEdArrival(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RecordEdArrival", sel, news, level, payload)
}

// ValidateRecordEdArrival ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RecordEdArrival) ValidateRecordEdArrival(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordEdArrival{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordEdArrival: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordEdArrival: %v\n", err)
    }
}
HOSPEOF

# ── AllocateBed (selector) ──
log "تولید AllocateBed"
mkdir -p "$CC_DIR/AllocateBed"
cat > "$CC_DIR/AllocateBed/go.mod" <<'HOSPEOF'
module allocatebed

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/AllocateBed/shared.go"
cat > "$CC_DIR/AllocateBed/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AllocateBed — نوع رفتاری: selector
// کانال‌ها: bedchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type AllocateBed struct {
    HospitalBase
}

// AllocateBed بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *AllocateBed) AllocateBed(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "AllocateBed", sel, news, level, payload)
}

// ValidateAllocateBed ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *AllocateBed) ValidateAllocateBed(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&AllocateBed{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode AllocateBed: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode AllocateBed: %v\n", err)
    }
}
HOSPEOF

# ── ReleaseBed (ledger) ──
log "تولید ReleaseBed"
mkdir -p "$CC_DIR/ReleaseBed"
cat > "$CC_DIR/ReleaseBed/go.mod" <<'HOSPEOF'
module releasebed

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReleaseBed/shared.go"
cat > "$CC_DIR/ReleaseBed/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReleaseBed — نوع رفتاری: ledger
// کانال‌ها: bedchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReleaseBed struct {
    HospitalBase
}

// ReleaseBed ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReleaseBed) ReleaseBed(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReleaseBed", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReleaseBed{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReleaseBed: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReleaseBed: %v\n", err)
    }
}
HOSPEOF

# ── ReserveIcuBed (selector) ──
log "تولید ReserveIcuBed"
mkdir -p "$CC_DIR/ReserveIcuBed"
cat > "$CC_DIR/ReserveIcuBed/go.mod" <<'HOSPEOF'
module reserveicubed

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReserveIcuBed/shared.go"
cat > "$CC_DIR/ReserveIcuBed/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReserveIcuBed — نوع رفتاری: selector
// کانال‌ها: bedchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReserveIcuBed struct {
    HospitalBase
}

// ReserveIcuBed بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *ReserveIcuBed) ReserveIcuBed(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "ReserveIcuBed", sel, news, level, payload)
}

// ValidateReserveIcuBed ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *ReserveIcuBed) ValidateReserveIcuBed(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&ReserveIcuBed{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReserveIcuBed: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReserveIcuBed: %v\n", err)
    }
}
HOSPEOF

# ── ReportBedCensus (ledger) ──
log "تولید ReportBedCensus"
mkdir -p "$CC_DIR/ReportBedCensus"
cat > "$CC_DIR/ReportBedCensus/go.mod" <<'HOSPEOF'
module reportbedcensus

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportBedCensus/shared.go"
cat > "$CC_DIR/ReportBedCensus/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportBedCensus — نوع رفتاری: ledger
// کانال‌ها: bedchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportBedCensus struct {
    HospitalBase
}

// ReportBedCensus ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportBedCensus) ReportBedCensus(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportBedCensus", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportBedCensus{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportBedCensus: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportBedCensus: %v\n", err)
    }
}
HOSPEOF

# ── RequestBedCapacity (selector) ──
log "تولید RequestBedCapacity"
mkdir -p "$CC_DIR/RequestBedCapacity"
cat > "$CC_DIR/RequestBedCapacity/go.mod" <<'HOSPEOF'
module requestbedcapacity

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestBedCapacity/shared.go"
cat > "$CC_DIR/RequestBedCapacity/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestBedCapacity — نوع رفتاری: selector
// کانال‌ها: bedchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestBedCapacity struct {
    HospitalBase
}

// RequestBedCapacity بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestBedCapacity) RequestBedCapacity(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestBedCapacity", sel, news, level, payload)
}

// ValidateRequestBedCapacity ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestBedCapacity) ValidateRequestBedCapacity(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestBedCapacity{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestBedCapacity: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestBedCapacity: %v\n", err)
    }
}
HOSPEOF

# ── ScheduleSurgery (selector) ──
log "تولید ScheduleSurgery"
mkdir -p "$CC_DIR/ScheduleSurgery"
cat > "$CC_DIR/ScheduleSurgery/go.mod" <<'HOSPEOF'
module schedulesurgery

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ScheduleSurgery/shared.go"
cat > "$CC_DIR/ScheduleSurgery/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ScheduleSurgery — نوع رفتاری: selector
// کانال‌ها: surgerychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ScheduleSurgery struct {
    HospitalBase
}

// ScheduleSurgery بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *ScheduleSurgery) ScheduleSurgery(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "ScheduleSurgery", sel, news, level, payload)
}

// ValidateScheduleSurgery ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *ScheduleSurgery) ValidateScheduleSurgery(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&ScheduleSurgery{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ScheduleSurgery: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ScheduleSurgery: %v\n", err)
    }
}
HOSPEOF

# ── ReserveOrSlot (selector) ──
log "تولید ReserveOrSlot"
mkdir -p "$CC_DIR/ReserveOrSlot"
cat > "$CC_DIR/ReserveOrSlot/go.mod" <<'HOSPEOF'
module reserveorslot

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReserveOrSlot/shared.go"
cat > "$CC_DIR/ReserveOrSlot/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReserveOrSlot — نوع رفتاری: selector
// کانال‌ها: surgerychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReserveOrSlot struct {
    HospitalBase
}

// ReserveOrSlot بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *ReserveOrSlot) ReserveOrSlot(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "ReserveOrSlot", sel, news, level, payload)
}

// ValidateReserveOrSlot ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *ReserveOrSlot) ValidateReserveOrSlot(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&ReserveOrSlot{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReserveOrSlot: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReserveOrSlot: %v\n", err)
    }
}
HOSPEOF

# ── CancelSurgery (ledger) ──
log "تولید CancelSurgery"
mkdir -p "$CC_DIR/CancelSurgery"
cat > "$CC_DIR/CancelSurgery/go.mod" <<'HOSPEOF'
module cancelsurgery

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/CancelSurgery/shared.go"
cat > "$CC_DIR/CancelSurgery/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// CancelSurgery — نوع رفتاری: ledger
// کانال‌ها: surgerychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type CancelSurgery struct {
    HospitalBase
}

// CancelSurgery ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *CancelSurgery) CancelSurgery(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "CancelSurgery", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&CancelSurgery{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode CancelSurgery: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode CancelSurgery: %v\n", err)
    }
}
HOSPEOF

# ── RecordSurgicalOutcome (ledger) ──
log "تولید RecordSurgicalOutcome"
mkdir -p "$CC_DIR/RecordSurgicalOutcome"
cat > "$CC_DIR/RecordSurgicalOutcome/go.mod" <<'HOSPEOF'
module recordsurgicaloutcome

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordSurgicalOutcome/shared.go"
cat > "$CC_DIR/RecordSurgicalOutcome/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordSurgicalOutcome — نوع رفتاری: ledger
// کانال‌ها: surgerychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordSurgicalOutcome struct {
    HospitalBase
}

// RecordSurgicalOutcome ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordSurgicalOutcome) RecordSurgicalOutcome(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordSurgicalOutcome", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordSurgicalOutcome{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordSurgicalOutcome: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordSurgicalOutcome: %v\n", err)
    }
}
HOSPEOF

# ── RequestEmergencyOr (selector) ──
log "تولید RequestEmergencyOr"
mkdir -p "$CC_DIR/RequestEmergencyOr"
cat > "$CC_DIR/RequestEmergencyOr/go.mod" <<'HOSPEOF'
module requestemergencyor

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestEmergencyOr/shared.go"
cat > "$CC_DIR/RequestEmergencyOr/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestEmergencyOr — نوع رفتاری: selector
// کانال‌ها: surgerychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestEmergencyOr struct {
    HospitalBase
}

// RequestEmergencyOr بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestEmergencyOr) RequestEmergencyOr(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestEmergencyOr", sel, news, level, payload)
}

// ValidateRequestEmergencyOr ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestEmergencyOr) ValidateRequestEmergencyOr(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestEmergencyOr{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestEmergencyOr: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestEmergencyOr: %v\n", err)
    }
}
HOSPEOF

# ── RegisterDevice (ledger) ──
log "تولید RegisterDevice"
mkdir -p "$CC_DIR/RegisterDevice"
cat > "$CC_DIR/RegisterDevice/go.mod" <<'HOSPEOF'
module registerdevice

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RegisterDevice/shared.go"
cat > "$CC_DIR/RegisterDevice/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RegisterDevice — نوع رفتاری: ledger
// کانال‌ها: equipmentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RegisterDevice struct {
    HospitalBase
}

// RegisterDevice ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RegisterDevice) RegisterDevice(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RegisterDevice", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RegisterDevice{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RegisterDevice: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RegisterDevice: %v\n", err)
    }
}
HOSPEOF

# ── ReserveDevice (selector) ──
log "تولید ReserveDevice"
mkdir -p "$CC_DIR/ReserveDevice"
cat > "$CC_DIR/ReserveDevice/go.mod" <<'HOSPEOF'
module reservedevice

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReserveDevice/shared.go"
cat > "$CC_DIR/ReserveDevice/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReserveDevice — نوع رفتاری: selector
// کانال‌ها: equipmentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReserveDevice struct {
    HospitalBase
}

// ReserveDevice بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *ReserveDevice) ReserveDevice(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "ReserveDevice", sel, news, level, payload)
}

// ValidateReserveDevice ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *ReserveDevice) ValidateReserveDevice(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&ReserveDevice{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReserveDevice: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReserveDevice: %v\n", err)
    }
}
HOSPEOF

# ── ReleaseDevice (ledger) ──
log "تولید ReleaseDevice"
mkdir -p "$CC_DIR/ReleaseDevice"
cat > "$CC_DIR/ReleaseDevice/go.mod" <<'HOSPEOF'
module releasedevice

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReleaseDevice/shared.go"
cat > "$CC_DIR/ReleaseDevice/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReleaseDevice — نوع رفتاری: ledger
// کانال‌ها: equipmentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReleaseDevice struct {
    HospitalBase
}

// ReleaseDevice ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReleaseDevice) ReleaseDevice(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReleaseDevice", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReleaseDevice{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReleaseDevice: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReleaseDevice: %v\n", err)
    }
}
HOSPEOF

# ── ReportDeviceFault (ledger) ──
log "تولید ReportDeviceFault"
mkdir -p "$CC_DIR/ReportDeviceFault"
cat > "$CC_DIR/ReportDeviceFault/go.mod" <<'HOSPEOF'
module reportdevicefault

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportDeviceFault/shared.go"
cat > "$CC_DIR/ReportDeviceFault/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportDeviceFault — نوع رفتاری: ledger
// کانال‌ها: equipmentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportDeviceFault struct {
    HospitalBase
}

// ReportDeviceFault ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportDeviceFault) ReportDeviceFault(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportDeviceFault", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportDeviceFault{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportDeviceFault: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportDeviceFault: %v\n", err)
    }
}
HOSPEOF

# ── LogDeviceMaintenance (ledger) ──
log "تولید LogDeviceMaintenance"
mkdir -p "$CC_DIR/LogDeviceMaintenance"
cat > "$CC_DIR/LogDeviceMaintenance/go.mod" <<'HOSPEOF'
module logdevicemaintenance

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogDeviceMaintenance/shared.go"
cat > "$CC_DIR/LogDeviceMaintenance/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogDeviceMaintenance — نوع رفتاری: ledger
// کانال‌ها: equipmentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogDeviceMaintenance struct {
    HospitalBase
}

// LogDeviceMaintenance ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogDeviceMaintenance) LogDeviceMaintenance(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogDeviceMaintenance", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogDeviceMaintenance{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogDeviceMaintenance: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogDeviceMaintenance: %v\n", err)
    }
}
HOSPEOF

# ── PrescribeDrug (guarded) ──
log "تولید PrescribeDrug"
mkdir -p "$CC_DIR/PrescribeDrug"
cat > "$CC_DIR/PrescribeDrug/go.mod" <<'HOSPEOF'
module prescribedrug

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/PrescribeDrug/shared.go"
cat > "$CC_DIR/PrescribeDrug/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// PrescribeDrug — نوع رفتاری: guarded
// کانال‌ها: pharmacychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type PrescribeDrug struct {
    HospitalBase
}

// PrescribeDrug تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *PrescribeDrug) PrescribeDrug(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "PrescribeDrug", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&PrescribeDrug{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode PrescribeDrug: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode PrescribeDrug: %v\n", err)
    }
}
HOSPEOF

# ── DispenseDrug (guarded) ──
log "تولید DispenseDrug"
mkdir -p "$CC_DIR/DispenseDrug"
cat > "$CC_DIR/DispenseDrug/go.mod" <<'HOSPEOF'
module dispensedrug

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/DispenseDrug/shared.go"
cat > "$CC_DIR/DispenseDrug/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// DispenseDrug — نوع رفتاری: guarded
// کانال‌ها: pharmacychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type DispenseDrug struct {
    HospitalBase
}

// DispenseDrug تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *DispenseDrug) DispenseDrug(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "DispenseDrug", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&DispenseDrug{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode DispenseDrug: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode DispenseDrug: %v\n", err)
    }
}
HOSPEOF

# ── VerifyDrugSafety (guarded) ──
log "تولید VerifyDrugSafety"
mkdir -p "$CC_DIR/VerifyDrugSafety"
cat > "$CC_DIR/VerifyDrugSafety/go.mod" <<'HOSPEOF'
module verifydrugsafety

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/VerifyDrugSafety/shared.go"
cat > "$CC_DIR/VerifyDrugSafety/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// VerifyDrugSafety — نوع رفتاری: guarded
// کانال‌ها: pharmacychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type VerifyDrugSafety struct {
    HospitalBase
}

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
    payload := fmt.Sprintf("{\"drug\":\"%s\",\"dose\":%d}", drugCode, orderedMicro)
    return s.commit(ctx, id, "VerifyDrugSafety", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&VerifyDrugSafety{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode VerifyDrugSafety: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode VerifyDrugSafety: %v\n", err)
    }
}
HOSPEOF

# ── RegisterDrugBatch (ledger) ──
log "تولید RegisterDrugBatch"
mkdir -p "$CC_DIR/RegisterDrugBatch"
cat > "$CC_DIR/RegisterDrugBatch/go.mod" <<'HOSPEOF'
module registerdrugbatch

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RegisterDrugBatch/shared.go"
cat > "$CC_DIR/RegisterDrugBatch/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RegisterDrugBatch — نوع رفتاری: ledger
// کانال‌ها: pharmacychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RegisterDrugBatch struct {
    HospitalBase
}

// RegisterDrugBatch ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RegisterDrugBatch) RegisterDrugBatch(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RegisterDrugBatch", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RegisterDrugBatch{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RegisterDrugBatch: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RegisterDrugBatch: %v\n", err)
    }
}
HOSPEOF

# ── RecallDrugBatch (guarded) ──
log "تولید RecallDrugBatch"
mkdir -p "$CC_DIR/RecallDrugBatch"
cat > "$CC_DIR/RecallDrugBatch/go.mod" <<'HOSPEOF'
module recalldrugbatch

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecallDrugBatch/shared.go"
cat > "$CC_DIR/RecallDrugBatch/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecallDrugBatch — نوع رفتاری: guarded
// کانال‌ها: pharmacychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecallDrugBatch struct {
    HospitalBase
}

// RecallDrugBatch تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *RecallDrugBatch) RecallDrugBatch(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "RecallDrugBatch", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecallDrugBatch{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecallDrugBatch: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecallDrugBatch: %v\n", err)
    }
}
HOSPEOF

# ── ReturnDrug (ledger) ──
log "تولید ReturnDrug"
mkdir -p "$CC_DIR/ReturnDrug"
cat > "$CC_DIR/ReturnDrug/go.mod" <<'HOSPEOF'
module returndrug

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReturnDrug/shared.go"
cat > "$CC_DIR/ReturnDrug/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReturnDrug — نوع رفتاری: ledger
// کانال‌ها: pharmacychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReturnDrug struct {
    HospitalBase
}

// ReturnDrug ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReturnDrug) ReturnDrug(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReturnDrug", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReturnDrug{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReturnDrug: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReturnDrug: %v\n", err)
    }
}
HOSPEOF

# ── CheckDrugInteraction (guarded) ──
log "تولید CheckDrugInteraction"
mkdir -p "$CC_DIR/CheckDrugInteraction"
cat > "$CC_DIR/CheckDrugInteraction/go.mod" <<'HOSPEOF'
module checkdruginteraction

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/CheckDrugInteraction/shared.go"
cat > "$CC_DIR/CheckDrugInteraction/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// CheckDrugInteraction — نوع رفتاری: guarded
// کانال‌ها: pharmacychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type CheckDrugInteraction struct {
    HospitalBase
}

// CheckDrugInteraction تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *CheckDrugInteraction) CheckDrugInteraction(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "CheckDrugInteraction", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&CheckDrugInteraction{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode CheckDrugInteraction: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode CheckDrugInteraction: %v\n", err)
    }
}
HOSPEOF

# ── RegisterBloodUnit (ledger) ──
log "تولید RegisterBloodUnit"
mkdir -p "$CC_DIR/RegisterBloodUnit"
cat > "$CC_DIR/RegisterBloodUnit/go.mod" <<'HOSPEOF'
module registerbloodunit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RegisterBloodUnit/shared.go"
cat > "$CC_DIR/RegisterBloodUnit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RegisterBloodUnit — نوع رفتاری: ledger
// کانال‌ها: bloodchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RegisterBloodUnit struct {
    HospitalBase
}

// RegisterBloodUnit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RegisterBloodUnit) RegisterBloodUnit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RegisterBloodUnit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RegisterBloodUnit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RegisterBloodUnit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RegisterBloodUnit: %v\n", err)
    }
}
HOSPEOF

# ── RequestBloodUnit (guarded) ──
log "تولید RequestBloodUnit"
mkdir -p "$CC_DIR/RequestBloodUnit"
cat > "$CC_DIR/RequestBloodUnit/go.mod" <<'HOSPEOF'
module requestbloodunit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestBloodUnit/shared.go"
cat > "$CC_DIR/RequestBloodUnit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestBloodUnit — نوع رفتاری: guarded
// کانال‌ها: bloodchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestBloodUnit struct {
    HospitalBase
}

// RequestBloodUnit تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *RequestBloodUnit) RequestBloodUnit(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "RequestBloodUnit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestBloodUnit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestBloodUnit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestBloodUnit: %v\n", err)
    }
}
HOSPEOF

# ── IssueBloodUnit (guarded) ──
log "تولید IssueBloodUnit"
mkdir -p "$CC_DIR/IssueBloodUnit"
cat > "$CC_DIR/IssueBloodUnit/go.mod" <<'HOSPEOF'
module issuebloodunit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/IssueBloodUnit/shared.go"
cat > "$CC_DIR/IssueBloodUnit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// IssueBloodUnit — نوع رفتاری: guarded
// کانال‌ها: bloodchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type IssueBloodUnit struct {
    HospitalBase
}

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
        "{\"unit\":\"%s\",\"donor\":%d,\"recipient\":%d,\"product\":%d,\"mask\":%d}",
        unitID, donorType, recipientType, product,
        BloodDonorMask(recipientType, product))
    return s.commit(ctx, id, "IssueBloodUnit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

// ValidateIssueBloodUnit ماسک گروه‌های مجاز را بدون نوشتن برمی‌گرداند.
func (s *IssueBloodUnit) ValidateIssueBloodUnit(ctx contractapi.TransactionContextInterface,
    recipientType, product int64) (int64, error) {
    return BloodDonorMask(recipientType, product), nil
}

func main() {
    cc, err := contractapi.NewChaincode(&IssueBloodUnit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode IssueBloodUnit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode IssueBloodUnit: %v\n", err)
    }
}
HOSPEOF

# ── CrossMatchScreen (guarded) ──
log "تولید CrossMatchScreen"
mkdir -p "$CC_DIR/CrossMatchScreen"
cat > "$CC_DIR/CrossMatchScreen/go.mod" <<'HOSPEOF'
module crossmatchscreen

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/CrossMatchScreen/shared.go"
cat > "$CC_DIR/CrossMatchScreen/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// CrossMatchScreen — نوع رفتاری: guarded
// کانال‌ها: bloodchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type CrossMatchScreen struct {
    HospitalBase
}

// CrossMatchScreen غربال سازگاری پیش از cross-match کامل.
func (s *CrossMatchScreen) CrossMatchScreen(ctx contractapi.TransactionContextInterface,
    id string, donorType, recipientType, product int64) error {

    ok := BloodCompatible(donorType, recipientType, product)
    payload := fmt.Sprintf("{\"donor\":%d,\"recipient\":%d,\"compatible\":%t}",
        donorType, recipientType, ok)
    if !ok {
        return fmt.Errorf("غربال ناموفق: %s", payload)
    }
    return s.commit(ctx, id, "CrossMatchScreen", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&CrossMatchScreen{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode CrossMatchScreen: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode CrossMatchScreen: %v\n", err)
    }
}
HOSPEOF

# ── ReturnBloodUnit (ledger) ──
log "تولید ReturnBloodUnit"
mkdir -p "$CC_DIR/ReturnBloodUnit"
cat > "$CC_DIR/ReturnBloodUnit/go.mod" <<'HOSPEOF'
module returnbloodunit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReturnBloodUnit/shared.go"
cat > "$CC_DIR/ReturnBloodUnit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReturnBloodUnit — نوع رفتاری: ledger
// کانال‌ها: bloodchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReturnBloodUnit struct {
    HospitalBase
}

// ReturnBloodUnit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReturnBloodUnit) ReturnBloodUnit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReturnBloodUnit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReturnBloodUnit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReturnBloodUnit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReturnBloodUnit: %v\n", err)
    }
}
HOSPEOF

# ── ReportBloodInventory (ledger) ──
log "تولید ReportBloodInventory"
mkdir -p "$CC_DIR/ReportBloodInventory"
cat > "$CC_DIR/ReportBloodInventory/go.mod" <<'HOSPEOF'
module reportbloodinventory

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportBloodInventory/shared.go"
cat > "$CC_DIR/ReportBloodInventory/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportBloodInventory — نوع رفتاری: ledger
// کانال‌ها: bloodchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportBloodInventory struct {
    HospitalBase
}

// ReportBloodInventory ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportBloodInventory) ReportBloodInventory(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportBloodInventory", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportBloodInventory{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportBloodInventory: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportBloodInventory: %v\n", err)
    }
}
HOSPEOF

# ── OrderLabTest (ledger) ──
log "تولید OrderLabTest"
mkdir -p "$CC_DIR/OrderLabTest"
cat > "$CC_DIR/OrderLabTest/go.mod" <<'HOSPEOF'
module orderlabtest

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/OrderLabTest/shared.go"
cat > "$CC_DIR/OrderLabTest/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// OrderLabTest — نوع رفتاری: ledger
// کانال‌ها: labchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type OrderLabTest struct {
    HospitalBase
}

// OrderLabTest ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *OrderLabTest) OrderLabTest(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "OrderLabTest", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&OrderLabTest{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode OrderLabTest: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode OrderLabTest: %v\n", err)
    }
}
HOSPEOF

# ── RecordLabResult (ledger) ──
log "تولید RecordLabResult"
mkdir -p "$CC_DIR/RecordLabResult"
cat > "$CC_DIR/RecordLabResult/go.mod" <<'HOSPEOF'
module recordlabresult

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordLabResult/shared.go"
cat > "$CC_DIR/RecordLabResult/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordLabResult — نوع رفتاری: ledger
// کانال‌ها: labchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordLabResult struct {
    HospitalBase
}

// RecordLabResult ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordLabResult) RecordLabResult(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordLabResult", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordLabResult{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordLabResult: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordLabResult: %v\n", err)
    }
}
HOSPEOF

# ── RequestLabCapacity (selector) ──
log "تولید RequestLabCapacity"
mkdir -p "$CC_DIR/RequestLabCapacity"
cat > "$CC_DIR/RequestLabCapacity/go.mod" <<'HOSPEOF'
module requestlabcapacity

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestLabCapacity/shared.go"
cat > "$CC_DIR/RequestLabCapacity/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestLabCapacity — نوع رفتاری: selector
// کانال‌ها: labchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestLabCapacity struct {
    HospitalBase
}

// RequestLabCapacity بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestLabCapacity) RequestLabCapacity(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestLabCapacity", sel, news, level, payload)
}

// ValidateRequestLabCapacity ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestLabCapacity) ValidateRequestLabCapacity(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestLabCapacity{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestLabCapacity: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestLabCapacity: %v\n", err)
    }
}
HOSPEOF

# ── FlagCriticalResult (guarded) ──
log "تولید FlagCriticalResult"
mkdir -p "$CC_DIR/FlagCriticalResult"
cat > "$CC_DIR/FlagCriticalResult/go.mod" <<'HOSPEOF'
module flagcriticalresult

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/FlagCriticalResult/shared.go"
cat > "$CC_DIR/FlagCriticalResult/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// FlagCriticalResult — نوع رفتاری: guarded
// کانال‌ها: labchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type FlagCriticalResult struct {
    HospitalBase
}

// FlagCriticalResult تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *FlagCriticalResult) FlagCriticalResult(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "FlagCriticalResult", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&FlagCriticalResult{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode FlagCriticalResult: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode FlagCriticalResult: %v\n", err)
    }
}
HOSPEOF

# ── OrderImaging (ledger) ──
log "تولید OrderImaging"
mkdir -p "$CC_DIR/OrderImaging"
cat > "$CC_DIR/OrderImaging/go.mod" <<'HOSPEOF'
module orderimaging

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/OrderImaging/shared.go"
cat > "$CC_DIR/OrderImaging/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// OrderImaging — نوع رفتاری: ledger
// کانال‌ها: imagingchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type OrderImaging struct {
    HospitalBase
}

// OrderImaging ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *OrderImaging) OrderImaging(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "OrderImaging", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&OrderImaging{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode OrderImaging: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode OrderImaging: %v\n", err)
    }
}
HOSPEOF

# ── RecordImagingReport (ledger) ──
log "تولید RecordImagingReport"
mkdir -p "$CC_DIR/RecordImagingReport"
cat > "$CC_DIR/RecordImagingReport/go.mod" <<'HOSPEOF'
module recordimagingreport

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordImagingReport/shared.go"
cat > "$CC_DIR/RecordImagingReport/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordImagingReport — نوع رفتاری: ledger
// کانال‌ها: imagingchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordImagingReport struct {
    HospitalBase
}

// RecordImagingReport ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordImagingReport) RecordImagingReport(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordImagingReport", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordImagingReport{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordImagingReport: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordImagingReport: %v\n", err)
    }
}
HOSPEOF

# ── RequestImagingSlot (selector) ──
log "تولید RequestImagingSlot"
mkdir -p "$CC_DIR/RequestImagingSlot"
cat > "$CC_DIR/RequestImagingSlot/go.mod" <<'HOSPEOF'
module requestimagingslot

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestImagingSlot/shared.go"
cat > "$CC_DIR/RequestImagingSlot/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestImagingSlot — نوع رفتاری: selector
// کانال‌ها: imagingchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestImagingSlot struct {
    HospitalBase
}

// RequestImagingSlot بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestImagingSlot) RequestImagingSlot(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestImagingSlot", sel, news, level, payload)
}

// ValidateRequestImagingSlot ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestImagingSlot) ValidateRequestImagingSlot(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestImagingSlot{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestImagingSlot: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestImagingSlot: %v\n", err)
    }
}
HOSPEOF

# ── RegisterStaff (ledger) ──
log "تولید RegisterStaff"
mkdir -p "$CC_DIR/RegisterStaff"
cat > "$CC_DIR/RegisterStaff/go.mod" <<'HOSPEOF'
module registerstaff

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RegisterStaff/shared.go"
cat > "$CC_DIR/RegisterStaff/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RegisterStaff — نوع رفتاری: ledger
// کانال‌ها: staffchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RegisterStaff struct {
    HospitalBase
}

// RegisterStaff ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RegisterStaff) RegisterStaff(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RegisterStaff", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RegisterStaff{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RegisterStaff: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RegisterStaff: %v\n", err)
    }
}
HOSPEOF

# ── AssignShift (ledger) ──
log "تولید AssignShift"
mkdir -p "$CC_DIR/AssignShift"
cat > "$CC_DIR/AssignShift/go.mod" <<'HOSPEOF'
module assignshift

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/AssignShift/shared.go"
cat > "$CC_DIR/AssignShift/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AssignShift — نوع رفتاری: ledger
// کانال‌ها: staffchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type AssignShift struct {
    HospitalBase
}

// AssignShift ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *AssignShift) AssignShift(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "AssignShift", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&AssignShift{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode AssignShift: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode AssignShift: %v\n", err)
    }
}
HOSPEOF

# ── RequestOnCall (selector) ──
log "تولید RequestOnCall"
mkdir -p "$CC_DIR/RequestOnCall"
cat > "$CC_DIR/RequestOnCall/go.mod" <<'HOSPEOF'
module requestoncall

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestOnCall/shared.go"
cat > "$CC_DIR/RequestOnCall/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestOnCall — نوع رفتاری: selector
// کانال‌ها: staffchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestOnCall struct {
    HospitalBase
}

// RequestOnCall بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestOnCall) RequestOnCall(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestOnCall", sel, news, level, payload)
}

// ValidateRequestOnCall ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestOnCall) ValidateRequestOnCall(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestOnCall{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestOnCall: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestOnCall: %v\n", err)
    }
}
HOSPEOF

# ── RecordCredential (ledger) ──
log "تولید RecordCredential"
mkdir -p "$CC_DIR/RecordCredential"
cat > "$CC_DIR/RecordCredential/go.mod" <<'HOSPEOF'
module recordcredential

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordCredential/shared.go"
cat > "$CC_DIR/RecordCredential/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordCredential — نوع رفتاری: ledger
// کانال‌ها: staffchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordCredential struct {
    HospitalBase
}

// RecordCredential ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordCredential) RecordCredential(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordCredential", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordCredential{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordCredential: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordCredential: %v\n", err)
    }
}
HOSPEOF

# ── RevokeCredential (ledger) ──
log "تولید RevokeCredential"
mkdir -p "$CC_DIR/RevokeCredential"
cat > "$CC_DIR/RevokeCredential/go.mod" <<'HOSPEOF'
module revokecredential

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RevokeCredential/shared.go"
cat > "$CC_DIR/RevokeCredential/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RevokeCredential — نوع رفتاری: ledger
// کانال‌ها: staffchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RevokeCredential struct {
    HospitalBase
}

// RevokeCredential ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RevokeCredential) RevokeCredential(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RevokeCredential", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RevokeCredential{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RevokeCredential: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RevokeCredential: %v\n", err)
    }
}
HOSPEOF

# ── CreateReferral (selector) ──
log "تولید CreateReferral"
mkdir -p "$CC_DIR/CreateReferral"
cat > "$CC_DIR/CreateReferral/go.mod" <<'HOSPEOF'
module createreferral

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/CreateReferral/shared.go"
cat > "$CC_DIR/CreateReferral/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// CreateReferral — نوع رفتاری: selector
// کانال‌ها: referralchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type CreateReferral struct {
    HospitalBase
}

// CreateReferral بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *CreateReferral) CreateReferral(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "CreateReferral", sel, news, level, payload)
}

// ValidateCreateReferral ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *CreateReferral) ValidateCreateReferral(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&CreateReferral{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode CreateReferral: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode CreateReferral: %v\n", err)
    }
}
HOSPEOF

# ── AcceptReferral (ledger) ──
log "تولید AcceptReferral"
mkdir -p "$CC_DIR/AcceptReferral"
cat > "$CC_DIR/AcceptReferral/go.mod" <<'HOSPEOF'
module acceptreferral

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/AcceptReferral/shared.go"
cat > "$CC_DIR/AcceptReferral/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AcceptReferral — نوع رفتاری: ledger
// کانال‌ها: referralchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type AcceptReferral struct {
    HospitalBase
}

// AcceptReferral ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *AcceptReferral) AcceptReferral(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "AcceptReferral", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&AcceptReferral{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode AcceptReferral: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode AcceptReferral: %v\n", err)
    }
}
HOSPEOF

# ── RejectReferral (ledger) ──
log "تولید RejectReferral"
mkdir -p "$CC_DIR/RejectReferral"
cat > "$CC_DIR/RejectReferral/go.mod" <<'HOSPEOF'
module rejectreferral

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RejectReferral/shared.go"
cat > "$CC_DIR/RejectReferral/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RejectReferral — نوع رفتاری: ledger
// کانال‌ها: referralchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RejectReferral struct {
    HospitalBase
}

// RejectReferral ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RejectReferral) RejectReferral(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RejectReferral", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RejectReferral{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RejectReferral: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RejectReferral: %v\n", err)
    }
}
HOSPEOF

# ── TransferPatient (selector) ──
log "تولید TransferPatient"
mkdir -p "$CC_DIR/TransferPatient"
cat > "$CC_DIR/TransferPatient/go.mod" <<'HOSPEOF'
module transferpatient

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/TransferPatient/shared.go"
cat > "$CC_DIR/TransferPatient/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// TransferPatient — نوع رفتاری: selector
// کانال‌ها: referralchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type TransferPatient struct {
    HospitalBase
}

// TransferPatient بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *TransferPatient) TransferPatient(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "TransferPatient", sel, news, level, payload)
}

// ValidateTransferPatient ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *TransferPatient) ValidateTransferPatient(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&TransferPatient{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode TransferPatient: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode TransferPatient: %v\n", err)
    }
}
HOSPEOF

# ── RequestSpecialistOpinion (selector) ──
log "تولید RequestSpecialistOpinion"
mkdir -p "$CC_DIR/RequestSpecialistOpinion"
cat > "$CC_DIR/RequestSpecialistOpinion/go.mod" <<'HOSPEOF'
module requestspecialistopinion

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestSpecialistOpinion/shared.go"
cat > "$CC_DIR/RequestSpecialistOpinion/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestSpecialistOpinion — نوع رفتاری: selector
// کانال‌ها: referralchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestSpecialistOpinion struct {
    HospitalBase
}

// RequestSpecialistOpinion بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestSpecialistOpinion) RequestSpecialistOpinion(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestSpecialistOpinion", sel, news, level, payload)
}

// ValidateRequestSpecialistOpinion ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestSpecialistOpinion) ValidateRequestSpecialistOpinion(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestSpecialistOpinion{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestSpecialistOpinion: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestSpecialistOpinion: %v\n", err)
    }
}
HOSPEOF

# ── CloseReferral (ledger) ──
log "تولید CloseReferral"
mkdir -p "$CC_DIR/CloseReferral"
cat > "$CC_DIR/CloseReferral/go.mod" <<'HOSPEOF'
module closereferral

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/CloseReferral/shared.go"
cat > "$CC_DIR/CloseReferral/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// CloseReferral — نوع رفتاری: ledger
// کانال‌ها: referralchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type CloseReferral struct {
    HospitalBase
}

// CloseReferral ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *CloseReferral) CloseReferral(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "CloseReferral", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&CloseReferral{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode CloseReferral: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode CloseReferral: %v\n", err)
    }
}
HOSPEOF

# ── DispatchAmbulance (selector) ──
log "تولید DispatchAmbulance"
mkdir -p "$CC_DIR/DispatchAmbulance"
cat > "$CC_DIR/DispatchAmbulance/go.mod" <<'HOSPEOF'
module dispatchambulance

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/DispatchAmbulance/shared.go"
cat > "$CC_DIR/DispatchAmbulance/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// DispatchAmbulance — نوع رفتاری: selector
// کانال‌ها: emergencychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type DispatchAmbulance struct {
    HospitalBase
}

// DispatchAmbulance بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *DispatchAmbulance) DispatchAmbulance(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "DispatchAmbulance", sel, news, level, payload)
}

// ValidateDispatchAmbulance ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *DispatchAmbulance) ValidateDispatchAmbulance(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&DispatchAmbulance{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode DispatchAmbulance: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode DispatchAmbulance: %v\n", err)
    }
}
HOSPEOF

# ── AssignAmbulanceDestination (selector) ──
log "تولید AssignAmbulanceDestination"
mkdir -p "$CC_DIR/AssignAmbulanceDestination"
cat > "$CC_DIR/AssignAmbulanceDestination/go.mod" <<'HOSPEOF'
module assignambulancedestination

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/AssignAmbulanceDestination/shared.go"
cat > "$CC_DIR/AssignAmbulanceDestination/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AssignAmbulanceDestination — نوع رفتاری: selector
// کانال‌ها: emergencychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type AssignAmbulanceDestination struct {
    HospitalBase
}

// AssignAmbulanceDestination بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *AssignAmbulanceDestination) AssignAmbulanceDestination(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "AssignAmbulanceDestination", sel, news, level, payload)
}

// ValidateAssignAmbulanceDestination ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *AssignAmbulanceDestination) ValidateAssignAmbulanceDestination(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&AssignAmbulanceDestination{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode AssignAmbulanceDestination: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode AssignAmbulanceDestination: %v\n", err)
    }
}
HOSPEOF

# ── ReportMassCasualty (selector) ──
log "تولید ReportMassCasualty"
mkdir -p "$CC_DIR/ReportMassCasualty"
cat > "$CC_DIR/ReportMassCasualty/go.mod" <<'HOSPEOF'
module reportmasscasualty

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportMassCasualty/shared.go"
cat > "$CC_DIR/ReportMassCasualty/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportMassCasualty — نوع رفتاری: selector
// کانال‌ها: emergencychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportMassCasualty struct {
    HospitalBase
}

// ReportMassCasualty بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *ReportMassCasualty) ReportMassCasualty(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "ReportMassCasualty", sel, news, level, payload)
}

// ValidateReportMassCasualty ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *ReportMassCasualty) ValidateReportMassCasualty(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportMassCasualty{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportMassCasualty: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportMassCasualty: %v\n", err)
    }
}
HOSPEOF

# ── ActivateCrisisProtocol (ledger) ──
log "تولید ActivateCrisisProtocol"
mkdir -p "$CC_DIR/ActivateCrisisProtocol"
cat > "$CC_DIR/ActivateCrisisProtocol/go.mod" <<'HOSPEOF'
module activatecrisisprotocol

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ActivateCrisisProtocol/shared.go"
cat > "$CC_DIR/ActivateCrisisProtocol/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ActivateCrisisProtocol — نوع رفتاری: ledger
// کانال‌ها: emergencychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ActivateCrisisProtocol struct {
    HospitalBase
}

// ActivateCrisisProtocol ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ActivateCrisisProtocol) ActivateCrisisProtocol(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ActivateCrisisProtocol", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ActivateCrisisProtocol{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ActivateCrisisProtocol: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ActivateCrisisProtocol: %v\n", err)
    }
}
HOSPEOF

# ── ReleaseAmbulance (ledger) ──
log "تولید ReleaseAmbulance"
mkdir -p "$CC_DIR/ReleaseAmbulance"
cat > "$CC_DIR/ReleaseAmbulance/go.mod" <<'HOSPEOF'
module releaseambulance

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReleaseAmbulance/shared.go"
cat > "$CC_DIR/ReleaseAmbulance/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReleaseAmbulance — نوع رفتاری: ledger
// کانال‌ها: emergencychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReleaseAmbulance struct {
    HospitalBase
}

// ReleaseAmbulance ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReleaseAmbulance) ReleaseAmbulance(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReleaseAmbulance", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReleaseAmbulance{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReleaseAmbulance: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReleaseAmbulance: %v\n", err)
    }
}
HOSPEOF

# ── RequestPrehospitalDestination (selector) ──
log "تولید RequestPrehospitalDestination"
mkdir -p "$CC_DIR/RequestPrehospitalDestination"
cat > "$CC_DIR/RequestPrehospitalDestination/go.mod" <<'HOSPEOF'
module requestprehospitaldestination

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestPrehospitalDestination/shared.go"
cat > "$CC_DIR/RequestPrehospitalDestination/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestPrehospitalDestination — نوع رفتاری: selector
// کانال‌ها: emergencychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestPrehospitalDestination struct {
    HospitalBase
}

// RequestPrehospitalDestination بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestPrehospitalDestination) RequestPrehospitalDestination(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestPrehospitalDestination", sel, news, level, payload)
}

// ValidateRequestPrehospitalDestination ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestPrehospitalDestination) ValidateRequestPrehospitalDestination(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestPrehospitalDestination{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestPrehospitalDestination: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestPrehospitalDestination: %v\n", err)
    }
}
HOSPEOF

# ── VerifyEligibility (guarded) ──
log "تولید VerifyEligibility"
mkdir -p "$CC_DIR/VerifyEligibility"
cat > "$CC_DIR/VerifyEligibility/go.mod" <<'HOSPEOF'
module verifyeligibility

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/VerifyEligibility/shared.go"
cat > "$CC_DIR/VerifyEligibility/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// VerifyEligibility — نوع رفتاری: guarded
// کانال‌ها: insurancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type VerifyEligibility struct {
    HospitalBase
}

// VerifyEligibility تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *VerifyEligibility) VerifyEligibility(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "VerifyEligibility", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&VerifyEligibility{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode VerifyEligibility: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode VerifyEligibility: %v\n", err)
    }
}
HOSPEOF

# ── SubmitClaim (guarded) ──
log "تولید SubmitClaim"
mkdir -p "$CC_DIR/SubmitClaim"
cat > "$CC_DIR/SubmitClaim/go.mod" <<'HOSPEOF'
module submitclaim

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/SubmitClaim/shared.go"
cat > "$CC_DIR/SubmitClaim/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// SubmitClaim — نوع رفتاری: guarded
// کانال‌ها: insurancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type SubmitClaim struct {
    HospitalBase
}

// SubmitClaim تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *SubmitClaim) SubmitClaim(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "SubmitClaim", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&SubmitClaim{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode SubmitClaim: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode SubmitClaim: %v\n", err)
    }
}
HOSPEOF

# ── AdjudicateClaim (guarded) ──
log "تولید AdjudicateClaim"
mkdir -p "$CC_DIR/AdjudicateClaim"
cat > "$CC_DIR/AdjudicateClaim/go.mod" <<'HOSPEOF'
module adjudicateclaim

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/AdjudicateClaim/shared.go"
cat > "$CC_DIR/AdjudicateClaim/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AdjudicateClaim — نوع رفتاری: guarded
// کانال‌ها: insurancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type AdjudicateClaim struct {
    HospitalBase
}

// AdjudicateClaim سهم بیمه و بیمار را حساب و ثبت می‌کند.
func (s *AdjudicateClaim) AdjudicateClaim(ctx contractapi.TransactionContextInterface,
    id, claimID string,
    tariffMicro, coverageMilli, deductibleMicro, remainingCapMicro int64) error {

    if tariffMicro <= 0 {
        return fmt.Errorf("تعرفه باید مثبت باشد")
    }
    r := ComputeClaim(tariffMicro, coverageMilli, deductibleMicro, remainingCapMicro)
    payload := fmt.Sprintf(
        "{\"claim\":\"%s\",\"billed\":%d,\"covered\":%d,\"patient\":%d,\"capped\":%d}",
        claimID, r.Billed, r.Covered, r.PatientPay, r.CappedBy)
    return s.commit(ctx, id, "AdjudicateClaim", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

// ValidateAdjudicateClaim محاسبه بدون نوشتن.
func (s *AdjudicateClaim) ValidateAdjudicateClaim(ctx contractapi.TransactionContextInterface,
    tariffMicro, coverageMilli, deductibleMicro, remainingCapMicro int64) (*ClaimResult, error) {
    r := ComputeClaim(tariffMicro, coverageMilli, deductibleMicro, remainingCapMicro)
    return &r, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&AdjudicateClaim{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode AdjudicateClaim: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode AdjudicateClaim: %v\n", err)
    }
}
HOSPEOF

# ── SettleClaim (ledger) ──
log "تولید SettleClaim"
mkdir -p "$CC_DIR/SettleClaim"
cat > "$CC_DIR/SettleClaim/go.mod" <<'HOSPEOF'
module settleclaim

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/SettleClaim/shared.go"
cat > "$CC_DIR/SettleClaim/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// SettleClaim — نوع رفتاری: ledger
// کانال‌ها: insurancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type SettleClaim struct {
    HospitalBase
}

// SettleClaim ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *SettleClaim) SettleClaim(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "SettleClaim", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&SettleClaim{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode SettleClaim: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode SettleClaim: %v\n", err)
    }
}
HOSPEOF

# ── RejectClaim (ledger) ──
log "تولید RejectClaim"
mkdir -p "$CC_DIR/RejectClaim"
cat > "$CC_DIR/RejectClaim/go.mod" <<'HOSPEOF'
module rejectclaim

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RejectClaim/shared.go"
cat > "$CC_DIR/RejectClaim/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RejectClaim — نوع رفتاری: ledger
// کانال‌ها: insurancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RejectClaim struct {
    HospitalBase
}

// RejectClaim ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RejectClaim) RejectClaim(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RejectClaim", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RejectClaim{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RejectClaim: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RejectClaim: %v\n", err)
    }
}
HOSPEOF

# ── RecordCoveragePolicy (ledger) ──
log "تولید RecordCoveragePolicy"
mkdir -p "$CC_DIR/RecordCoveragePolicy"
cat > "$CC_DIR/RecordCoveragePolicy/go.mod" <<'HOSPEOF'
module recordcoveragepolicy

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordCoveragePolicy/shared.go"
cat > "$CC_DIR/RecordCoveragePolicy/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordCoveragePolicy — نوع رفتاری: ledger
// کانال‌ها: insurancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordCoveragePolicy struct {
    HospitalBase
}

// RecordCoveragePolicy ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordCoveragePolicy) RecordCoveragePolicy(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordCoveragePolicy", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordCoveragePolicy{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordCoveragePolicy: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordCoveragePolicy: %v\n", err)
    }
}
HOSPEOF

# ── RegisterSupplyItem (ledger) ──
log "تولید RegisterSupplyItem"
mkdir -p "$CC_DIR/RegisterSupplyItem"
cat > "$CC_DIR/RegisterSupplyItem/go.mod" <<'HOSPEOF'
module registersupplyitem

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RegisterSupplyItem/shared.go"
cat > "$CC_DIR/RegisterSupplyItem/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RegisterSupplyItem — نوع رفتاری: ledger
// کانال‌ها: supplychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RegisterSupplyItem struct {
    HospitalBase
}

// RegisterSupplyItem ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RegisterSupplyItem) RegisterSupplyItem(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RegisterSupplyItem", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RegisterSupplyItem{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RegisterSupplyItem: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RegisterSupplyItem: %v\n", err)
    }
}
HOSPEOF

# ── RecordShipment (ledger) ──
log "تولید RecordShipment"
mkdir -p "$CC_DIR/RecordShipment"
cat > "$CC_DIR/RecordShipment/go.mod" <<'HOSPEOF'
module recordshipment

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordShipment/shared.go"
cat > "$CC_DIR/RecordShipment/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordShipment — نوع رفتاری: ledger
// کانال‌ها: supplychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordShipment struct {
    HospitalBase
}

// RecordShipment ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordShipment) RecordShipment(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordShipment", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordShipment{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordShipment: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordShipment: %v\n", err)
    }
}
HOSPEOF

# ── ReceiveShipment (ledger) ──
log "تولید ReceiveShipment"
mkdir -p "$CC_DIR/ReceiveShipment"
cat > "$CC_DIR/ReceiveShipment/go.mod" <<'HOSPEOF'
module receiveshipment

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReceiveShipment/shared.go"
cat > "$CC_DIR/ReceiveShipment/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReceiveShipment — نوع رفتاری: ledger
// کانال‌ها: supplychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReceiveShipment struct {
    HospitalBase
}

// ReceiveShipment ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReceiveShipment) ReceiveShipment(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReceiveShipment", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReceiveShipment{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReceiveShipment: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReceiveShipment: %v\n", err)
    }
}
HOSPEOF

# ── ReportStockLevel (ledger) ──
log "تولید ReportStockLevel"
mkdir -p "$CC_DIR/ReportStockLevel"
cat > "$CC_DIR/ReportStockLevel/go.mod" <<'HOSPEOF'
module reportstocklevel

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportStockLevel/shared.go"
cat > "$CC_DIR/ReportStockLevel/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportStockLevel — نوع رفتاری: ledger
// کانال‌ها: supplychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportStockLevel struct {
    HospitalBase
}

// ReportStockLevel ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportStockLevel) ReportStockLevel(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportStockLevel", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportStockLevel{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportStockLevel: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportStockLevel: %v\n", err)
    }
}
HOSPEOF

# ── RequestRestock (selector) ──
log "تولید RequestRestock"
mkdir -p "$CC_DIR/RequestRestock"
cat > "$CC_DIR/RequestRestock/go.mod" <<'HOSPEOF'
module requestrestock

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RequestRestock/shared.go"
cat > "$CC_DIR/RequestRestock/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RequestRestock — نوع رفتاری: selector
// کانال‌ها: supplychannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RequestRestock struct {
    HospitalBase
}

// RequestRestock بیمار را تریاژ می‌کند، مرکز مقصد را خودش انتخاب می‌کند و
// در صورت نبود مرکز واجد شرایط، خروج از پنجره طلایی یا اشباع
// ظرفیت، تراکنش را رد می‌کند.
func (s *RequestRestock) RequestRestock(ctx contractapi.TransactionContextInterface,
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

    payload := fmt.Sprintf("{\"commit\":\"%s\",\"x\":%d,\"y\":%d,\"news2\":%d}",
        patientCommit, x, y, news.Total)
    return s.commit(ctx, id, "RequestRestock", sel, news, level, payload)
}

// ValidateRequestRestock ارزیابی بدون نوشتن — برای بررسی پیش از ارسال.
func (s *RequestRestock) ValidateRequestRestock(ctx contractapi.TransactionContextInterface,
    x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears int64) (*Selection, error) {

    sel, _, _, err := s.evaluate(ctx, "probe",
        x, y, rr, spo2, onOxygen, sbp, hr, avpu, tempMilliC, flags, ageYears)
    if err != nil {
        return nil, err
    }
    return &sel, nil
}

func main() {
    cc, err := contractapi.NewChaincode(&RequestRestock{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RequestRestock: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RequestRestock: %v\n", err)
    }
}
HOSPEOF

# ── MintResourceToken (market) ──
log "تولید MintResourceToken"
mkdir -p "$CC_DIR/MintResourceToken"
cat > "$CC_DIR/MintResourceToken/go.mod" <<'HOSPEOF'
module mintresourcetoken

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/MintResourceToken/shared.go"
cat > "$CC_DIR/MintResourceToken/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// MintResourceToken — نوع رفتاری: market
// کانال‌ها: marketchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type MintResourceToken struct {
    HospitalBase
}

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
}

func main() {
    cc, err := contractapi.NewChaincode(&MintResourceToken{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode MintResourceToken: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode MintResourceToken: %v\n", err)
    }
}
HOSPEOF

# ── TransferToken (market) ──
log "تولید TransferToken"
mkdir -p "$CC_DIR/TransferToken"
cat > "$CC_DIR/TransferToken/go.mod" <<'HOSPEOF'
module transfertoken

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/TransferToken/shared.go"
cat > "$CC_DIR/TransferToken/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// TransferToken — نوع رفتاری: market
// کانال‌ها: marketchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type TransferToken struct {
    HospitalBase
}


func main() {
    cc, err := contractapi.NewChaincode(&TransferToken{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode TransferToken: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode TransferToken: %v\n", err)
    }
}
HOSPEOF

# ── BalanceOf (market) ──
log "تولید BalanceOf"
mkdir -p "$CC_DIR/BalanceOf"
cat > "$CC_DIR/BalanceOf/go.mod" <<'HOSPEOF'
module balanceof

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/BalanceOf/shared.go"
cat > "$CC_DIR/BalanceOf/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// BalanceOf — نوع رفتاری: market
// کانال‌ها: marketchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type BalanceOf struct {
    HospitalBase
}


func main() {
    cc, err := contractapi.NewChaincode(&BalanceOf{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode BalanceOf: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode BalanceOf: %v\n", err)
    }
}
HOSPEOF

# ── ShareBedCapacity (market) ──
log "تولید ShareBedCapacity"
mkdir -p "$CC_DIR/ShareBedCapacity"
cat > "$CC_DIR/ShareBedCapacity/go.mod" <<'HOSPEOF'
module sharebedcapacity

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ShareBedCapacity/shared.go"
cat > "$CC_DIR/ShareBedCapacity/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ShareBedCapacity — نوع رفتاری: market
// کانال‌ها: marketchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ShareBedCapacity struct {
    HospitalBase
}

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
    payload := fmt.Sprintf("{\"lender\":\"%s\",\"borrower\":\"%s\",\"beds\":%d}",
        lender, borrower, beds)
    return s.commit(ctx, id, "ShareBedCapacity", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ShareBedCapacity{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ShareBedCapacity: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ShareBedCapacity: %v\n", err)
    }
}
HOSPEOF

# ── TradeOrSlot (market) ──
log "تولید TradeOrSlot"
mkdir -p "$CC_DIR/TradeOrSlot"
cat > "$CC_DIR/TradeOrSlot/go.mod" <<'HOSPEOF'
module tradeorslot

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/TradeOrSlot/shared.go"
cat > "$CC_DIR/TradeOrSlot/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// TradeOrSlot — نوع رفتاری: market
// کانال‌ها: marketchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type TradeOrSlot struct {
    HospitalBase
}

func (s *TradeOrSlot) TradeOrSlot(ctx contractapi.TransactionContextInterface,
    id, from, to string, amount, priceMicro int64) error {

    if amount <= 0 {
        return fmt.Errorf("مقدار باید مثبت باشد")
    }
    if err := s.TransferToken(ctx, to, from, priceMicro*amount); err != nil {
        return err
    }
    payload := fmt.Sprintf("{\"from\":\"%s\",\"to\":\"%s\",\"amount\":%d}",
        from, to, amount)
    return s.commit(ctx, id, "TradeOrSlot", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&TradeOrSlot{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode TradeOrSlot: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode TradeOrSlot: %v\n", err)
    }
}
HOSPEOF

# ── LendStaffHours (market) ──
log "تولید LendStaffHours"
mkdir -p "$CC_DIR/LendStaffHours"
cat > "$CC_DIR/LendStaffHours/go.mod" <<'HOSPEOF'
module lendstaffhours

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LendStaffHours/shared.go"
cat > "$CC_DIR/LendStaffHours/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LendStaffHours — نوع رفتاری: market
// کانال‌ها: marketchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LendStaffHours struct {
    HospitalBase
}

func (s *LendStaffHours) LendStaffHours(ctx contractapi.TransactionContextInterface,
    id, from, to string, amount, priceMicro int64) error {

    if amount <= 0 {
        return fmt.Errorf("مقدار باید مثبت باشد")
    }
    if err := s.TransferToken(ctx, to, from, priceMicro*amount); err != nil {
        return err
    }
    payload := fmt.Sprintf("{\"from\":\"%s\",\"to\":\"%s\",\"amount\":%d}",
        from, to, amount)
    return s.commit(ctx, id, "LendStaffHours", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LendStaffHours{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LendStaffHours: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LendStaffHours: %v\n", err)
    }
}
HOSPEOF

# ── GrantConsent (ledger) ──
log "تولید GrantConsent"
mkdir -p "$CC_DIR/GrantConsent"
cat > "$CC_DIR/GrantConsent/go.mod" <<'HOSPEOF'
module grantconsent

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/GrantConsent/shared.go"
cat > "$CC_DIR/GrantConsent/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// GrantConsent — نوع رفتاری: ledger
// کانال‌ها: consentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type GrantConsent struct {
    HospitalBase
}

// GrantConsent ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *GrantConsent) GrantConsent(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "GrantConsent", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&GrantConsent{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode GrantConsent: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode GrantConsent: %v\n", err)
    }
}
HOSPEOF

# ── RevokeConsent (ledger) ──
log "تولید RevokeConsent"
mkdir -p "$CC_DIR/RevokeConsent"
cat > "$CC_DIR/RevokeConsent/go.mod" <<'HOSPEOF'
module revokeconsent

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RevokeConsent/shared.go"
cat > "$CC_DIR/RevokeConsent/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RevokeConsent — نوع رفتاری: ledger
// کانال‌ها: consentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RevokeConsent struct {
    HospitalBase
}

// RevokeConsent ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RevokeConsent) RevokeConsent(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RevokeConsent", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RevokeConsent{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RevokeConsent: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RevokeConsent: %v\n", err)
    }
}
HOSPEOF

# ── CheckConsent (guarded) ──
log "تولید CheckConsent"
mkdir -p "$CC_DIR/CheckConsent"
cat > "$CC_DIR/CheckConsent/go.mod" <<'HOSPEOF'
module checkconsent

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/CheckConsent/shared.go"
cat > "$CC_DIR/CheckConsent/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// CheckConsent — نوع رفتاری: guarded
// کانال‌ها: consentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type CheckConsent struct {
    HospitalBase
}

// CheckConsent تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *CheckConsent) CheckConsent(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "CheckConsent", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&CheckConsent{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode CheckConsent: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode CheckConsent: %v\n", err)
    }
}
HOSPEOF

# ── ShareDataWithProvider (guarded) ──
log "تولید ShareDataWithProvider"
mkdir -p "$CC_DIR/ShareDataWithProvider"
cat > "$CC_DIR/ShareDataWithProvider/go.mod" <<'HOSPEOF'
module sharedatawithprovider

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ShareDataWithProvider/shared.go"
cat > "$CC_DIR/ShareDataWithProvider/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ShareDataWithProvider — نوع رفتاری: guarded
// کانال‌ها: consentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ShareDataWithProvider struct {
    HospitalBase
}

// ShareDataWithProvider تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *ShareDataWithProvider) ShareDataWithProvider(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "ShareDataWithProvider", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ShareDataWithProvider{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ShareDataWithProvider: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ShareDataWithProvider: %v\n", err)
    }
}
HOSPEOF

# ── LogDataAccess (ledger) ──
log "تولید LogDataAccess"
mkdir -p "$CC_DIR/LogDataAccess"
cat > "$CC_DIR/LogDataAccess/go.mod" <<'HOSPEOF'
module logdataaccess

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogDataAccess/shared.go"
cat > "$CC_DIR/LogDataAccess/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogDataAccess — نوع رفتاری: ledger
// کانال‌ها: consentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogDataAccess struct {
    HospitalBase
}

// LogDataAccess ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogDataAccess) LogDataAccess(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogDataAccess", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogDataAccess{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogDataAccess: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogDataAccess: %v\n", err)
    }
}
HOSPEOF

# ── EmergencyOverrideAccess (guarded) ──
log "تولید EmergencyOverrideAccess"
mkdir -p "$CC_DIR/EmergencyOverrideAccess"
cat > "$CC_DIR/EmergencyOverrideAccess/go.mod" <<'HOSPEOF'
module emergencyoverrideaccess

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/EmergencyOverrideAccess/shared.go"
cat > "$CC_DIR/EmergencyOverrideAccess/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// EmergencyOverrideAccess — نوع رفتاری: guarded
// کانال‌ها: consentchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type EmergencyOverrideAccess struct {
    HospitalBase
}

// EmergencyOverrideAccess تصمیم قطعی می‌گیرد: اگر شرط دامنه برقرار نباشد تراکنش
// رد می‌شود. شرط با پارامتر condition به قرارداد داده می‌شود تا
// منطق اختصاصی هر مرکز خارج از زنجیره بماند و آنچه روی زنجیره
// می‌رود فقط **نتیجه قابل ممیزی** باشد.
func (s *EmergencyOverrideAccess) EmergencyOverrideAccess(ctx contractapi.TransactionContextInterface,
    id, subject string, condition, threshold int64) error {

    if id == "" || subject == "" {
        return fmt.Errorf("شناسه و موضوع الزامی‌اند")
    }
    if condition < threshold {
        return fmt.Errorf("شرط برقرار نیست: %d < %d", condition, threshold)
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"condition\":%d,\"threshold\":%d}",
        subject, condition, threshold)
    return s.commit(ctx, id, "EmergencyOverrideAccess", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&EmergencyOverrideAccess{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode EmergencyOverrideAccess: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode EmergencyOverrideAccess: %v\n", err)
    }
}
HOSPEOF

# ── LogPatientAudit (ledger) ──
log "تولید LogPatientAudit"
mkdir -p "$CC_DIR/LogPatientAudit"
cat > "$CC_DIR/LogPatientAudit/go.mod" <<'HOSPEOF'
module logpatientaudit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogPatientAudit/shared.go"
cat > "$CC_DIR/LogPatientAudit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogPatientAudit — نوع رفتاری: ledger
// کانال‌ها: auditchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogPatientAudit struct {
    HospitalBase
}

// LogPatientAudit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogPatientAudit) LogPatientAudit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogPatientAudit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogPatientAudit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogPatientAudit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogPatientAudit: %v\n", err)
    }
}
HOSPEOF

# ── LogClinicalAudit (ledger) ──
log "تولید LogClinicalAudit"
mkdir -p "$CC_DIR/LogClinicalAudit"
cat > "$CC_DIR/LogClinicalAudit/go.mod" <<'HOSPEOF'
module logclinicalaudit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogClinicalAudit/shared.go"
cat > "$CC_DIR/LogClinicalAudit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogClinicalAudit — نوع رفتاری: ledger
// کانال‌ها: auditchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogClinicalAudit struct {
    HospitalBase
}

// LogClinicalAudit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogClinicalAudit) LogClinicalAudit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogClinicalAudit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogClinicalAudit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogClinicalAudit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogClinicalAudit: %v\n", err)
    }
}
HOSPEOF

# ── LogAccessAudit (ledger) ──
log "تولید LogAccessAudit"
mkdir -p "$CC_DIR/LogAccessAudit"
cat > "$CC_DIR/LogAccessAudit/go.mod" <<'HOSPEOF'
module logaccessaudit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogAccessAudit/shared.go"
cat > "$CC_DIR/LogAccessAudit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogAccessAudit — نوع رفتاری: ledger
// کانال‌ها: auditchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogAccessAudit struct {
    HospitalBase
}

// LogAccessAudit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogAccessAudit) LogAccessAudit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogAccessAudit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogAccessAudit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogAccessAudit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogAccessAudit: %v\n", err)
    }
}
HOSPEOF

# ── LogDrugAudit (ledger) ──
log "تولید LogDrugAudit"
mkdir -p "$CC_DIR/LogDrugAudit"
cat > "$CC_DIR/LogDrugAudit/go.mod" <<'HOSPEOF'
module logdrugaudit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogDrugAudit/shared.go"
cat > "$CC_DIR/LogDrugAudit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogDrugAudit — نوع رفتاری: ledger
// کانال‌ها: auditchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogDrugAudit struct {
    HospitalBase
}

// LogDrugAudit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogDrugAudit) LogDrugAudit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogDrugAudit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogDrugAudit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogDrugAudit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogDrugAudit: %v\n", err)
    }
}
HOSPEOF

# ── LogBloodAudit (ledger) ──
log "تولید LogBloodAudit"
mkdir -p "$CC_DIR/LogBloodAudit"
cat > "$CC_DIR/LogBloodAudit/go.mod" <<'HOSPEOF'
module logbloodaudit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogBloodAudit/shared.go"
cat > "$CC_DIR/LogBloodAudit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogBloodAudit — نوع رفتاری: ledger
// کانال‌ها: auditchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogBloodAudit struct {
    HospitalBase
}

// LogBloodAudit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogBloodAudit) LogBloodAudit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogBloodAudit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogBloodAudit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogBloodAudit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogBloodAudit: %v\n", err)
    }
}
HOSPEOF

# ── LogFinancialAudit (ledger) ──
log "تولید LogFinancialAudit"
mkdir -p "$CC_DIR/LogFinancialAudit"
cat > "$CC_DIR/LogFinancialAudit/go.mod" <<'HOSPEOF'
module logfinancialaudit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogFinancialAudit/shared.go"
cat > "$CC_DIR/LogFinancialAudit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogFinancialAudit — نوع رفتاری: ledger
// کانال‌ها: auditchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogFinancialAudit struct {
    HospitalBase
}

// LogFinancialAudit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogFinancialAudit) LogFinancialAudit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogFinancialAudit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogFinancialAudit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogFinancialAudit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogFinancialAudit: %v\n", err)
    }
}
HOSPEOF

# ── LogSystemAudit (ledger) ──
log "تولید LogSystemAudit"
mkdir -p "$CC_DIR/LogSystemAudit"
cat > "$CC_DIR/LogSystemAudit/go.mod" <<'HOSPEOF'
module logsystemaudit

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/LogSystemAudit/shared.go"
cat > "$CC_DIR/LogSystemAudit/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// LogSystemAudit — نوع رفتاری: ledger
// کانال‌ها: auditchannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type LogSystemAudit struct {
    HospitalBase
}

// LogSystemAudit ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *LogSystemAudit) LogSystemAudit(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "LogSystemAudit", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&LogSystemAudit{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode LogSystemAudit: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode LogSystemAudit: %v\n", err)
    }
}
HOSPEOF

# ── RecordAccreditation (ledger) ──
log "تولید RecordAccreditation"
mkdir -p "$CC_DIR/RecordAccreditation"
cat > "$CC_DIR/RecordAccreditation/go.mod" <<'HOSPEOF'
module recordaccreditation

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordAccreditation/shared.go"
cat > "$CC_DIR/RecordAccreditation/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordAccreditation — نوع رفتاری: ledger
// کانال‌ها: compliancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordAccreditation struct {
    HospitalBase
}

// RecordAccreditation ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordAccreditation) RecordAccreditation(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordAccreditation", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordAccreditation{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordAccreditation: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordAccreditation: %v\n", err)
    }
}
HOSPEOF

# ── ReportIncident (ledger) ──
log "تولید ReportIncident"
mkdir -p "$CC_DIR/ReportIncident"
cat > "$CC_DIR/ReportIncident/go.mod" <<'HOSPEOF'
module reportincident

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportIncident/shared.go"
cat > "$CC_DIR/ReportIncident/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportIncident — نوع رفتاری: ledger
// کانال‌ها: compliancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportIncident struct {
    HospitalBase
}

// ReportIncident ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportIncident) ReportIncident(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportIncident", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportIncident{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportIncident: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportIncident: %v\n", err)
    }
}
HOSPEOF

# ── RecordQualityIndicator (ledger) ──
log "تولید RecordQualityIndicator"
mkdir -p "$CC_DIR/RecordQualityIndicator"
cat > "$CC_DIR/RecordQualityIndicator/go.mod" <<'HOSPEOF'
module recordqualityindicator

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/RecordQualityIndicator/shared.go"
cat > "$CC_DIR/RecordQualityIndicator/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// RecordQualityIndicator — نوع رفتاری: ledger
// کانال‌ها: compliancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type RecordQualityIndicator struct {
    HospitalBase
}

// RecordQualityIndicator ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *RecordQualityIndicator) RecordQualityIndicator(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "RecordQualityIndicator", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&RecordQualityIndicator{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode RecordQualityIndicator: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode RecordQualityIndicator: %v\n", err)
    }
}
HOSPEOF

# ── VerifyProtocolAdherence (ledger) ──
log "تولید VerifyProtocolAdherence"
mkdir -p "$CC_DIR/VerifyProtocolAdherence"
cat > "$CC_DIR/VerifyProtocolAdherence/go.mod" <<'HOSPEOF'
module verifyprotocoladherence

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/VerifyProtocolAdherence/shared.go"
cat > "$CC_DIR/VerifyProtocolAdherence/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// VerifyProtocolAdherence — نوع رفتاری: ledger
// کانال‌ها: compliancechannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type VerifyProtocolAdherence struct {
    HospitalBase
}

// VerifyProtocolAdherence ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *VerifyProtocolAdherence) VerifyProtocolAdherence(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "VerifyProtocolAdherence", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&VerifyProtocolAdherence{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode VerifyProtocolAdherence: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode VerifyProtocolAdherence: %v\n", err)
    }
}
HOSPEOF

# ── ReportOccupancy (ledger) ──
log "تولید ReportOccupancy"
mkdir -p "$CC_DIR/ReportOccupancy"
cat > "$CC_DIR/ReportOccupancy/go.mod" <<'HOSPEOF'
module reportoccupancy

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportOccupancy/shared.go"
cat > "$CC_DIR/ReportOccupancy/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportOccupancy — نوع رفتاری: ledger
// کانال‌ها: analyticschannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportOccupancy struct {
    HospitalBase
}

// ReportOccupancy ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportOccupancy) ReportOccupancy(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportOccupancy", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportOccupancy{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportOccupancy: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportOccupancy: %v\n", err)
    }
}
HOSPEOF

# ── ReportWaitTime (ledger) ──
log "تولید ReportWaitTime"
mkdir -p "$CC_DIR/ReportWaitTime"
cat > "$CC_DIR/ReportWaitTime/go.mod" <<'HOSPEOF'
module reportwaittime

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportWaitTime/shared.go"
cat > "$CC_DIR/ReportWaitTime/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportWaitTime — نوع رفتاری: ledger
// کانال‌ها: analyticschannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportWaitTime struct {
    HospitalBase
}

// ReportWaitTime ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportWaitTime) ReportWaitTime(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportWaitTime", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportWaitTime{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportWaitTime: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportWaitTime: %v\n", err)
    }
}
HOSPEOF

# ── ReportOutcomeIndicator (ledger) ──
log "تولید ReportOutcomeIndicator"
mkdir -p "$CC_DIR/ReportOutcomeIndicator"
cat > "$CC_DIR/ReportOutcomeIndicator/go.mod" <<'HOSPEOF'
module reportoutcomeindicator

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportOutcomeIndicator/shared.go"
cat > "$CC_DIR/ReportOutcomeIndicator/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportOutcomeIndicator — نوع رفتاری: ledger
// کانال‌ها: analyticschannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportOutcomeIndicator struct {
    HospitalBase
}

// ReportOutcomeIndicator ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportOutcomeIndicator) ReportOutcomeIndicator(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportOutcomeIndicator", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportOutcomeIndicator{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportOutcomeIndicator: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportOutcomeIndicator: %v\n", err)
    }
}
HOSPEOF

# ── ReportEpidemicSignal (ledger) ──
log "تولید ReportEpidemicSignal"
mkdir -p "$CC_DIR/ReportEpidemicSignal"
cat > "$CC_DIR/ReportEpidemicSignal/go.mod" <<'HOSPEOF'
module reportepidemicsignal

go 1.21

require github.com/hyperledger/fabric-contract-api-go v1.2.1
HOSPEOF
cp "$SHARED_TMP" "$CC_DIR/ReportEpidemicSignal/shared.go"
cat > "$CC_DIR/ReportEpidemicSignal/chaincode.go" <<'HOSPEOF'
package main

import (
    "fmt"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ReportEpidemicSignal — نوع رفتاری: ledger
// کانال‌ها: analyticschannel
//
// HospitalBase را embed می‌کند و از آن پیکربندی، بذرکاری، تریاژ،
// انتخاب مرکز، حسابداری ظرفیت، بازار و پرس‌وجو را می‌گیرد.
type ReportEpidemicSignal struct {
    HospitalBase
}

// ReportEpidemicSignal ثبت کور. هیچ شرطی ندارد و هرگز رد نمی‌کند — به عمد، تا
// خط پایه‌ای برای سنجش «هزینه پیچیدگی chaincode» فراهم شود.
func (s *ReportEpidemicSignal) ReportEpidemicSignal(ctx contractapi.TransactionContextInterface,
    id, subject, detail string) error {

    if id == "" {
        return fmt.Errorf("شناسه رکورد الزامی است")
    }
    payload := fmt.Sprintf("{\"subject\":\"%s\",\"detail\":\"%s\"}", subject, detail)
    return s.commit(ctx, id, "ReportEpidemicSignal", Selection{Reason: AdmitOK},
        News2Result{}, 0, payload)
}

func main() {
    cc, err := contractapi.NewChaincode(&ReportEpidemicSignal{})
    if err != nil {
        fmt.Printf("خطا در ساخت chaincode ReportEpidemicSignal: %v\n", err)
        return
    }
    if err := cc.Start(); err != nil {
        fmt.Printf("خطا در اجرای chaincode ReportEpidemicSignal: %v\n", err)
    }
}
HOSPEOF

# ── کامپایل ──
# همه قراردادها یک shared.go دارند، پس اگر یکی کامپایل شود بقیه هم
# می‌شوند. اولی را کامل می‌سازیم و بقیه را فقط vet می‌کنیم.
log "کامپایل قرارداد اول برای اعتبارسنجی"
FIRST=$(ls "$CC_DIR" | head -1)
cd "$CC_DIR/$FIRST"
if ! go mod tidy >/dev/null 2>&1; then
  log "خطا: go mod tidy در $FIRST شکست خورد"
  exit 1
fi
if ! go build -o /dev/null . ; then
  log "خطا: کامپایل $FIRST شکست خورد — استقرار متوقف شد"
  exit 1
fi
log "کامپایل موفق. ${#} قرارداد آماده استقرار در $CC_DIR"
