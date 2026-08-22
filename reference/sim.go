package main

import (
	"fmt"
	"os"
	"sort"
)

/* sim.go — شبیه‌سازی مشخصه‌یابی هسته بالینی.
   با `go run .` اجرا می‌شود. جزئی از chaincode نیست؛ فقط برای
   گرفتن اعدادی که در گزارش قابل ارجاع باشند.                    */

const (
	simSeed     = "seed-1404"
	simGridM    = 30000 // شبکه ۳۰ کیلومتری
	simFacs     = 12
	simPatients = 20000
)

func main() {
	facs := SeedFacilities(simSeed, simFacs, simGridM)

	var levelCount [6]int
	var reasonCount [5]int
	var news2Hist [21]int
	loadPerFac := map[string]int{}
	travels := []int{}
	accepted := 0

	for i := 1; i <= simPatients; i++ {
		id := fmt.Sprintf("patient-%d", i)
		px, py := PlaceOnGrid(simSeed, id, simGridM)

		// علائم حیاتی از هش قطعی — توزیع طوری چیده شده که اکثریت
		// طبیعی باشند و دم توزیع بیماران بحرانی را بسازد.
		rr := skew(HashRange(0, 999, simSeed, id, "rr"), 10, 18, 6, 34)
		spo2 := 100 - skew(HashRange(0, 999, simSeed, id, "spo2"), 0, 3, 0, 18)
		sbp := skew(HashRange(0, 999, simSeed, id, "sbp"), 105, 140, 65, 215)
		hr := skew(HashRange(0, 999, simSeed, id, "hr"), 62, 92, 38, 148)
		tmp := skew(HashRange(0, 999, simSeed, id, "tmp"), 36400, 37200, 35200, 39800)
		age := HashRange(0, 95, simSeed, id, "age")

		ox := int64(0)
		if spo2 < 93 {
			ox = 1
		}
		avpu := int64(AvpuAlert)
		if HashRange(0, 999, simSeed, id, "avpu") > 975 {
			avpu = AvpuVoice
		}

		// پرچم‌های بالینی، هر کدام با احتمال کم
		flags := int64(0)
		for bit, p := range map[int64]int64{
			FlagAirway: 4, FlagCardiac: 22, FlagStroke: 16, FlagTrauma: 25,
			FlagHemorrage: 12, FlagSepsis: 18, FlagLabor: 20, FlagBurn: 5,
		} {
			if HashRange(0, 999, simSeed, id, fmt.Sprint("f", bit)) < p {
				flags |= bit
			}
		}

		n := News2(rr, spo2, ox, sbp, hr, avpu, tmp)
		news2Hist[clampI(n.Total, 0, 20)]++
		lvl, need := TriageLevel(n, flags, age)
		levelCount[lvl]++

		sel := SelectFacility(px, py, facs, need, GoldenWindowSec(lvl), 0)
		reasonCount[sel.Reason]++
		if sel.Reason == AdmitOK {
			accepted++
			loadPerFac[sel.FacilityID]++
			travels = append(travels, int(sel.TravelSec))
		}
	}

	out := os.Stdout
	fmt.Fprintf(out, "═══ شبیه‌سازی: %d بیمار، %d مرکز، شبکه %d کیلومتر ═══\n\n",
		simPatients, simFacs, simGridM/1000)

	fmt.Fprintln(out, "── توزیع سطح تریاژ ──")
	for l := 1; l <= 5; l++ {
		fmt.Fprintf(out, "  سطح %d : %6d  (%5.2f%%)\n", l, levelCount[l],
			100*float64(levelCount[l])/float64(simPatients))
	}

	fmt.Fprintln(out, "\n── نتیجه ارجاع ──")
	names := []string{"پذیرفته", "هیچ مرکزی نیست", "توانمندی ناموجود",
		"خارج از پنجره طلایی", "همه اشباع"}
	for i, c := range reasonCount {
		if c == 0 && i != 0 {
			continue
		}
		fmt.Fprintf(out, "  %-22s %6d  (%5.2f%%)\n", names[i], c,
			100*float64(c)/float64(simPatients))
	}

	fmt.Fprintln(out, "\n── زمان رسیدن (ثانیه) ──")
	sort.Ints(travels)
	for _, p := range []int{5, 25, 50, 75, 95, 99} {
		fmt.Fprintf(out, "  صدک %-3d : %5d ثانیه (%4.1f دقیقه)\n", p,
			pct(travels, p), float64(pct(travels, p))/60)
	}

	fmt.Fprintln(out, "\n── توزیع بار بین مراکز ──")
	ids := []string{}
	for k := range loadPerFac {
		ids = append(ids, k)
	}
	sort.Slice(ids, func(a, b int) bool { return loadPerFac[ids[a]] > loadPerFac[ids[b]] })
	for _, id := range ids {
		share := 100 * float64(loadPerFac[id]) / float64(accepted)
		fmt.Fprintf(out, "  %-12s %6d  (%5.2f%%)  %s\n", id, loadPerFac[id], share,
			bar(share))
	}

	fmt.Fprintln(out, "\n── هیستوگرام NEWS2 ──")
	for s := 0; s <= 20; s++ {
		if news2Hist[s] == 0 {
			continue
		}
		fmt.Fprintf(out, "  %2d : %6d %s\n", s, news2Hist[s],
			bar(400*float64(news2Hist[s])/float64(simPatients)))
	}
}

// skew یک عدد ۰..۹۹۹ را به توزیع کج با اکثریت در بازه [lo,hi] و
// دم تا [floor,ceil] می‌برد.
func skew(u, lo, hi, floor, ceil int64) int64 {
	switch {
	case u < 780: // ۷۸٪ در بازه طبیعی
		return lo + (u % (hi - lo + 1))
	case u < 930: // ۱۵٪ انحراف خفیف
		if u%2 == 0 {
			return lo - (u % maxI((lo-floor)/2, 1))
		}
		return hi + (u % maxI((ceil-hi)/2, 1))
	default: // ۷٪ دم
		if u%2 == 0 {
			return floor + (u % maxI((lo-floor)/2, 1))
		}
		return ceil - (u % maxI((ceil-hi)/2, 1))
	}
}

func pct(xs []int, p int) int {
	if len(xs) == 0 {
		return 0
	}
	i := p * (len(xs) - 1) / 100
	return xs[i]
}

func bar(v float64) string {
	n := int(v)
	if n > 60 {
		n = 60
	}
	s := ""
	for i := 0; i < n; i++ {
		s += "█"
	}
	return s
}
