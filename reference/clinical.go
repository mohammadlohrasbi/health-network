package main

import "fmt"

/* ═══════════════════════════════════════════════════════════════════════
   clinical.go — هسته قطعی (deterministic kernel) شبکه سلامت

   قرینه radio.go در پروژه 6G. همان محدودیت و به همان دلیل:

   فابریک نتیجه اجرای chaincode را روی چند peer **بایت‌به‌بایت** مقایسه
   می‌کند. اگر یک peer به عدد دیگری برسد، سیاست تأیید شکست می‌خورد
   (ENDORSEMENT_POLICY_FAILURE) و تراکنش رد می‌شود — بدون اینکه پیام
   خطای معناداری بدهد.

   بنابراین در این فایل:
     · فقط int64 — هیچ float32/float64
     · هیچ import از math (Log/Pow/Exp تضمین بیت‌به‌بیت بین معماری‌ها ندارند)
     · هیچ math/rand — تصادفی‌بودن از هش بذر می‌آید نه از مولد حالت‌دار
     · هیچ time.Now() — زمان فقط از txTimestamp(ctx) می‌آید
     · هیچ پیمایش map — ترتیب پیمایش map در Go عمداً تصادفی است

   واحدها (همه صحیح):
     دما            میلی‌درجه سلسیوس   36.5°C  → 36500
     فاصله          متر
     زمان           ثانیه
     مبلغ           میکرو‌واحد پول      1 ریال  → 1000000
     درصد/نسبت      میلی‌درصد          12.5%   → 12500
     وزن            گرم
     دوز            میکروگرم
   ═══════════════════════════════════════════════════════════════════════ */

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
