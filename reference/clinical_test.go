package main

import (
	"fmt"
	"sort"
	"testing"
)

/* ── NEWS2 در برابر نمونه‌های منتشرشده ────────────────────────── */

func TestNews2KnownCases(t *testing.T) {
	cases := []struct {
		name                             string
		rr, spo2, ox, sbp, hr, avpu, tmp int64
		total, band                      int64
	}{
		// بیمار کاملاً طبیعی
		{"طبیعی", 16, 98, 0, 120, 70, AvpuAlert, 36800, 0, 0},
		// هر پارامتر دقیقاً روی مرز بالای بازه طبیعی
		{"مرز بالای طبیعی", 20, 96, 0, 219, 90, AvpuAlert, 38000, 0, 0},
		// هر پارامتر دقیقاً روی مرز پایین بازه طبیعی
		{"مرز پایین طبیعی", 12, 96, 0, 111, 51, AvpuAlert, 36100, 0, 0},
		// تک‌پارامتر ۳: مجموع ۳ ولی باند ۱ (نه ۰)
		{"تک‌پارامتر سه", 16, 98, 0, 120, 35, AvpuAlert, 36800, 3, 1},
		// اکسیژن مکمل به تنهایی ۲ امتیاز
		{"اکسیژن مکمل", 16, 98, 1, 120, 70, AvpuAlert, 36800, 2, 0},
		// سپسیس شدید: تقریباً همه پارامترها مختل
		{"سپسیس شدید", 28, 90, 1, 85, 135, AvpuVoice, 39500, 19, 3},
		// هیپوترمی شدید تنها
		{"هیپوترمی", 16, 98, 0, 120, 70, AvpuAlert, 34500, 3, 1},
		// باند متوسط
		{"باند متوسط", 22, 94, 0, 105, 95, AvpuAlert, 38500, 6, 2},
	}
	for _, c := range cases {
		got := News2(c.rr, c.spo2, c.ox, c.sbp, c.hr, c.avpu, c.tmp)
		if got.Total != c.total {
			t.Errorf("%s: مجموع %d، انتظار %d (%+v)", c.name, got.Total, c.total, got)
		}
		if got.RiskBand != c.band {
			t.Errorf("%s: باند %d، انتظار %d", c.name, got.RiskBand, c.band)
		}
	}
}

// بیشینه نظری NEWS2 برابر ۲۰ است. اگر پیاده‌سازی بیشتر بدهد،
// یکی از جدول‌ها اشتباه است.
func TestNews2MaxIsTwenty(t *testing.T) {
	var maxSeen int64
	for rr := int64(0); rr <= 60; rr += 1 {
		for spo2 := int64(70); spo2 <= 100; spo2 += 3 {
			for sbp := int64(50); sbp <= 250; sbp += 10 {
				for hr := int64(20); hr <= 180; hr += 10 {
					for tmp := int64(33000); tmp <= 42000; tmp += 1000 {
						r := News2(rr, spo2, 1, sbp, hr, AvpuPain, tmp)
						if r.Total > maxSeen {
							maxSeen = r.Total
						}
					}
				}
			}
		}
	}
	if maxSeen != 20 {
		t.Fatalf("بیشینه NEWS2 برابر %d شد، باید ۲۰ باشد", maxSeen)
	}
}

// هیچ مرزی نباید پرش بیش از یک واحد بدهد در جایی که نباید،
// و هر پارامتر باید در بازه صفر تا سه بماند.
func TestNews2ComponentRange(t *testing.T) {
	for v := int64(-10); v <= 300; v++ {
		if s := news2Resp(v); s < 0 || s > 3 {
			t.Fatalf("تنفس %d → %d", v, s)
		}
		if s := news2Pulse(v); s < 0 || s > 3 {
			t.Fatalf("نبض %d → %d", v, s)
		}
		if s := news2Sbp(v); s < 0 || s > 3 {
			t.Fatalf("فشار %d → %d", v, s)
		}
	}
	for v := int64(0); v <= 100; v++ {
		if s := news2SpO2(v); s < 0 || s > 3 {
			t.Fatalf("اشباع %d → %d", v, s)
		}
	}
	for v := int64(30000); v <= 45000; v += 100 {
		if s := news2Temp(v); s < 0 || s > 3 {
			t.Fatalf("دما %d → %d", v, s)
		}
	}
}

/* ── سازگاری خونی در برابر جدول مرجع ───────────────────────── */

func TestBloodRbcTable(t *testing.T) {
	// شمار دهندگان مجاز برای هر گیرنده — عدد استاندارد.
	want := map[int64]int{
		BloodONeg: 1, BloodOPos: 2,
		BloodANeg: 2, BloodAPos: 4,
		BloodBNeg: 2, BloodBPos: 4,
		BloodABNeg: 4, BloodABPos: 8,
	}
	for rcp, n := range want {
		count := 0
		for d := int64(0); d < 8; d++ {
			if BloodCompatible(d, rcp, ProductRBC) {
				count++
			}
		}
		if count != n {
			t.Errorf("گیرنده %d: %d دهنده، انتظار %d", rcp, count, n)
		}
	}
	// O- دهنده همگانی گلبول قرمز
	for rcp := int64(0); rcp < 8; rcp++ {
		if !BloodCompatible(BloodONeg, rcp, ProductRBC) {
			t.Errorf("O- باید به %d بدهد", rcp)
		}
	}
	// AB+ فقط از خودش نمی‌گیرد بلکه از همه می‌گیرد ولی به کسی جز
	// خودش نمی‌دهد
	for rcp := int64(0); rcp < 7; rcp++ {
		if BloodCompatible(BloodABPos, rcp, ProductRBC) {
			t.Errorf("AB+ نباید به %d بدهد", rcp)
		}
	}
	// Rh منفی هرگز نباید از Rh مثبت بگیرد (گلبول قرمز)
	negatives := []int64{BloodONeg, BloodANeg, BloodBNeg, BloodABNeg}
	positives := []int64{BloodOPos, BloodAPos, BloodBPos, BloodABPos}
	for _, r := range negatives {
		for _, d := range positives {
			if BloodCompatible(d, r, ProductRBC) {
				t.Errorf("گیرنده Rh منفی %d نباید از Rh مثبت %d بگیرد", r, d)
			}
		}
	}
}

func TestBloodPlasmaIsReversed(t *testing.T) {
	// AB دهنده همگانی پلاسماست
	for rcp := int64(0); rcp < 8; rcp++ {
		if !BloodCompatible(BloodABPos, rcp, ProductPlasma) {
			t.Errorf("پلاسمای AB+ باید به %d برسد", rcp)
		}
	}
	// O فقط از O و از هر گروهی می‌گیرد — گیرنده O پلاسمای همه را
	// می‌پذیرد
	for d := int64(0); d < 8; d++ {
		if !BloodCompatible(d, BloodONeg, ProductPlasma) {
			t.Errorf("گیرنده O- باید پلاسمای %d را بپذیرد", d)
		}
	}
	// و برعکس: پلاسمای O فقط به O می‌رسد
	for rcp := int64(2); rcp < 8; rcp++ {
		if BloodCompatible(BloodONeg, rcp, ProductPlasma) {
			t.Errorf("پلاسمای O- نباید به %d برسد", rcp)
		}
	}
}

/* ── قطعیت: همان ورودی، همان خروجی، مستقل از ترتیب ─────────── */

func TestSelectFacilityDeterministic(t *testing.T) {
	facs := SeedFacilities("seed-42", 8, 20000)
	need := int64(CapEmergency | CapICU)

	first := SelectFacility(5000, 5000, facs, need, 3600, 0)
	if first.Reason != AdmitOK || first.FacilityID == "" {
		t.Fatalf("سناریوی پایه باید بپذیرد، شد %+v", first)
	}

	// همان ورودی هزار بار → همان خروجی
	for i := 0; i < 1000; i++ {
		got := SelectFacility(5000, 5000, facs, need, 3600, 0)
		if got != first {
			t.Fatalf("تکرار %d نتیجه متفاوت داد", i)
		}
	}

	// ترتیب ورودی نباید نتیجه را عوض کند — این همان چیزی است که
	// اگر tie-break روی شناسه نبود، شکست می‌خورد
	perm := make([]Facility, len(facs))
	copy(perm, facs)
	for round := 0; round < 200; round++ {
		// جابه‌جایی قطعی ولی متفاوت در هر دور
		sort.SliceStable(perm, func(a, b int) bool {
			return hashUniform(perm[a].ID, fmt.Sprint(round)) <
				hashUniform(perm[b].ID, fmt.Sprint(round))
		})
		got := SelectFacility(5000, 5000, perm, need, 3600, 0)
		if got.FacilityID != first.FacilityID || got.TotalSec != first.TotalSec {
			t.Fatalf("دور %d: ترتیب ورودی نتیجه را عوض کرد (%s در برابر %s)",
				round, got.FacilityID, first.FacilityID)
		}
	}
}

// تساوی کامل: دو مرکز با فاصله دقیقاً یکسان از بیمار. بدون
// tie-break روی شناسه، انتخاب به ترتیب slice وابسته می‌شد.
func TestSelectFacilityExactTie(t *testing.T) {
	a := Facility{ID: "hosp-b", X: 1000, Y: 0, Capability: 0xFFFF,
		TotalBeds: 10, SpeedKmh: 45, Congestion: 1000}
	b := Facility{ID: "hosp-a", X: -1000, Y: 0, Capability: 0xFFFF,
		TotalBeds: 10, SpeedKmh: 45, Congestion: 1000}

	s1 := SelectFacility(0, 0, []Facility{a, b}, CapEmergency, 3600, 0)
	s2 := SelectFacility(0, 0, []Facility{b, a}, CapEmergency, 3600, 0)

	if s1.Reason != AdmitOK {
		t.Fatalf("هر دو مرکز واجد شرایط و نزدیک‌اند، باید بپذیرد: %+v", s1)
	}
	// ۱۳۰۰ متر جاده با ۴۵ km/h ≈ ۱۰۴ ثانیه، به‌علاوه ۱۸۰ ثانیه اعزام
	if s1.TravelSec < 240 || s1.TravelSec > 320 {
		t.Fatalf("زمان سفر %d ثانیه — واحدها اشتباه‌اند", s1.TravelSec)
	}

	if s1.FacilityID != s2.FacilityID {
		t.Fatalf("تساوی کامل به ترتیب حساس است: %s در برابر %s",
			s1.FacilityID, s2.FacilityID)
	}
	if s1.FacilityID != "hosp-a" {
		t.Fatalf("در تساوی باید شناسه کوچک‌تر برنده باشد، شد %s", s1.FacilityID)
	}
}

/* ── هش: بهمن‌سازی واقعاً کار می‌کند؟ ────────────────────────── */

// این همان آزمونی است که در پروژه 6G باگ همبستگی ‑۰.۴۲ را گرفت.
// شناسه‌های متوالی نباید هش‌های همبسته بدهند.
func TestHashAvalanche(t *testing.T) {
	const n = 4000
	xs := make([]float64, n)
	ys := make([]float64, n)
	for i := 0; i < n; i++ {
		xs[i] = float64(hashUniform("seed", fmt.Sprintf("patient-%d", i)))
		ys[i] = float64(hashUniform("seed", fmt.Sprintf("patient-%d", i+1)))
	}
	r := pearson(xs, ys)
	if r > 0.05 || r < -0.05 {
		t.Fatalf("هش شناسه‌های متوالی همبستگی %.4f دارد — بهمن‌سازی ناکافی", r)
	}

	// و توزیع باید یکنواخت باشد: کای‌دو روی ۱۶ سطل
	var buckets [16]int
	for i := 0; i < n*4; i++ {
		v := hashUniform("s", fmt.Sprintf("id-%d", i))
		buckets[v*16/(1<<20)]++
	}
	exp := float64(n*4) / 16
	var chi float64
	for _, b := range buckets {
		d := float64(b) - exp
		chi += d * d / exp
	}
	// ۱۵ درجه آزادی، مقدار بحرانی ۰.۰۰۱ حدود ۳۷.۷
	if chi > 37.7 {
		t.Fatalf("توزیع هش یکنواخت نیست: chi²=%.1f", chi)
	}
}

func pearson(a, b []float64) float64 {
	n := float64(len(a))
	var sa, sb float64
	for i := range a {
		sa += a[i]
		sb += b[i]
	}
	ma, mb := sa/n, sb/n
	var num, da, db float64
	for i := range a {
		x, y := a[i]-ma, b[i]-mb
		num += x * y
		da += x * x
		db += y * y
	}
	if da == 0 || db == 0 {
		return 0
	}
	return num / sqrtF(da*db)
}

func sqrtF(x float64) float64 {
	if x <= 0 {
		return 0
	}
	z := x
	for i := 0; i < 60; i++ {
		z = (z + x/z) / 2
	}
	return z
}

// CommitID نباید برخورد قابل ملاحظه بدهد و باید به نمک حساس باشد.
func TestCommitID(t *testing.T) {
	seen := map[string]bool{}
	const n = 50000
	for i := 0; i < n; i++ {
		c := CommitID("salt-of-hospital-7", fmt.Sprintf("%010d", 1000000000+i))
		if len(c) != 16 {
			t.Fatalf("طول تعهد %d", len(c))
		}
		if seen[c] {
			t.Fatalf("برخورد در %d نمونه", i)
		}
		seen[c] = true
	}
	// همان شناسه با نمک متفاوت باید تعهد کاملاً متفاوت بدهد
	a := CommitID("salt-A", "0012345678")
	b := CommitID("salt-B", "0012345678")
	if a == b {
		t.Fatal("تعهد به نمک حساس نیست")
	}
	// و باید تکرارپذیر باشد
	if a != CommitID("salt-A", "0012345678") {
		t.Fatal("تعهد تکرارپذیر نیست")
	}
}

/* ── بیمه ────────────────────────────────────────────────── */

func TestComputeClaim(t *testing.T) {
	// تعرفه ۱۰۰۰۰۰۰ میکرو، پوشش ۷۰٪، فرانشیز ۱۰۰۰۰۰، بدون سقف
	r := ComputeClaim(1000000, 70000, 100000, -1)
	if r.Deductible != 100000 {
		t.Errorf("فرانشیز %d", r.Deductible)
	}
	if r.Covered != 630000 { // ۷۰٪ از ۹۰۰۰۰۰
		t.Errorf("پوشش %d، انتظار ۶۳۰۰۰۰", r.Covered)
	}
	if r.Covered+r.PatientPay != r.Billed {
		t.Errorf("مجموع نمی‌خواند: %d + %d ≠ %d", r.Covered, r.PatientPay, r.Billed)
	}
	// سقف باید ببرد
	r2 := ComputeClaim(1000000, 70000, 100000, 500000)
	if r2.Covered != 500000 || r2.CappedBy != 1 {
		t.Errorf("سقف اعمال نشد: %+v", r2)
	}
	// فرانشیز بزرگ‌تر از تعرفه نباید منفی بدهد
	r3 := ComputeClaim(50000, 70000, 100000, -1)
	if r3.Covered != 0 || r3.PatientPay != 50000 {
		t.Errorf("فرانشیز بزرگ: %+v", r3)
	}
	// این اتحاد باید همیشه برقرار باشد
	for tar := int64(0); tar < 5000000; tar += 37000 {
		for cov := int64(0); cov <= 100000; cov += 7000 {
			x := ComputeClaim(tar, cov, 120000, -1)
			if x.Covered+x.PatientPay != x.Billed {
				t.Fatalf("نقض اتحاد در tar=%d cov=%d: %+v", tar, cov, x)
			}
			if x.Covered < 0 || x.PatientPay < 0 {
				t.Fatalf("مقدار منفی در tar=%d cov=%d: %+v", tar, cov, x)
			}
		}
	}
}

/* ── دوز ─────────────────────────────────────────────────── */

func TestDoseCheck(t *testing.T) {
	// بیمار ۷۰ کیلو، محدوده ۱۰–۲۰ میکروگرم بر کیلو → ۷۰۰–۱۴۰۰
	w := int64(70000)
	if DoseCheck(w, 10, 20, 1000, 1000) != 0 {
		t.Error("۱۰۰۰ باید در محدوده باشد")
	}
	if DoseCheck(w, 10, 20, 600, 1000) != -1 {
		t.Error("۶۰۰ باید کم باشد")
	}
	if DoseCheck(w, 10, 20, 1500, 1000) != 1 {
		t.Error("۱۵۰۰ باید زیاد باشد")
	}
	// نارسایی کلیه سقف را نصف می‌کند → ۷۰۰
	if DoseCheck(w, 10, 20, 1000, 500) != 1 {
		t.Error("با تعدیل کلیه ۱۰۰۰ باید زیاد باشد")
	}
	// مرزها دقیقاً باید در محدوده بمانند
	if DoseCheck(w, 10, 20, 700, 1000) != 0 || DoseCheck(w, 10, 20, 1400, 1000) != 0 {
		t.Error("مرزها باید پذیرفته شوند")
	}
}

/* ── انتظار و اولویت ────────────────────────────────────── */

func TestWaitMonotone(t *testing.T) {
	// انتظار باید با افزایش اشغال یکنوا افزایش یابد
	var prev int64 = -1
	for used := int64(0); used <= 100; used++ {
		w := EstimatedWaitSec(20, 100, used)
		if w < prev {
			t.Fatalf("انتظار در اشغال %d کاهش یافت: %d پس از %d", used, w, prev)
		}
		prev = w
	}
}

func TestPriorityOrdering(t *testing.T) {
	// سطح تریاژ باید بر همه چیز غالب باشد: بیمار سطح ۱ تازه‌رسیده
	// باید بر بیمار سطح ۳ که ۶ ساعت منتظر بوده مقدم باشد
	l1 := PriorityScore(1, 8, 0, 40)
	l3 := PriorityScore(3, 4, 21600, 40)
	if l1 <= l3 {
		t.Fatalf("سطح ۱ (%d) باید بر سطح ۳ با انتظار طولانی (%d) مقدم باشد", l1, l3)
	}
	// در سطح یکسان، انتظار بیشتر باید مقدم باشد
	a := PriorityScore(3, 4, 3600, 40)
	b := PriorityScore(3, 4, 0, 40)
	if a <= b {
		t.Fatal("در سطح یکسان انتظار بیشتر باید مقدم باشد")
	}
}

/* ── تریاژ: پرچم‌ها فقط بالا می‌برند ─────────────────────── */

func TestTriageFlagsOnlyEscalate(t *testing.T) {
	// بیمار با علائم حیاتی کاملاً طبیعی ولی علائم سکته
	normal := News2(16, 98, 0, 120, 70, AvpuAlert, 36800)
	lvl, need := TriageLevel(normal, FlagStroke, 55)
	if lvl != 1 {
		t.Fatalf("سکته با علائم طبیعی باید سطح ۱ باشد، شد %d", lvl)
	}
	if need&CapStroke == 0 || need&CapImaging == 0 {
		t.Fatal("سکته باید واحد سکته و تصویربرداری بخواهد")
	}
	// بدون پرچم، همان بیمار سطح ۵
	lvl2, _ := TriageLevel(normal, 0, 55)
	if lvl2 != 5 {
		t.Fatalf("بیمار طبیعی بدون پرچم باید سطح ۵ باشد، شد %d", lvl2)
	}
	// پرچم نباید سطح را پایین بیاورد: بیمار بحرانی با پرچم زایمان
	crit := News2(28, 90, 1, 85, 135, AvpuVoice, 39500)
	lvl3, _ := TriageLevel(crit, FlagLabor, 30)
	if lvl3 != 1 {
		t.Fatalf("بیمار بحرانی باید سطح ۱ بماند، شد %d", lvl3)
	}
	// نوزاد باید NICU بخواهد
	_, needInf := TriageLevel(normal, 0, 0)
	if needInf&CapNICU == 0 || needInf&CapPediatric == 0 {
		t.Fatal("نوزاد باید NICU و اطفال بخواهد")
	}
}
