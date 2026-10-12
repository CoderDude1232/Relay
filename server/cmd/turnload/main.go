// Command turnload runs on the TURN box and reports whether it is close to its
// limits, so relayd can move new calls to the backup TURN service before
// coturn or the host is overwhelmed.
//
// It samples /proc every second: inbound bandwidth and packet rate on the
// public interface, and CPU use. "Overloaded" is any of them above its
// threshold for -trip consecutive seconds; it clears only after -clear
// consecutive seconds below 70% of every threshold (hysteresis, so calls
// don't bounce between providers).
//
// It also keeps this month's data total (saved in -state-dir, so it survives
// restarts) and reports overloaded once it reaches -monthly-threshold of
// -monthly-limit-gb, until the month rolls over, so calls move to the backup
// TURN instead of running into the host's transfer allowance.
//
// GET /status returns {"overloaded":bool,"reason":"...","rxMbps":..,"rxPps":..,"cpu":..,
//
//	"monthUsedGB":..,"monthLimitGB":..}
//
// Expose it only to the relay host; it isn't sensitive but needn't be public.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type sample struct {
	rxBytes, rxPackets, txBytes uint64
	cpuBusy, cpuTotal           uint64
}

type status struct {
	Overloaded bool    `json:"overloaded"`
	Reason     string  `json:"reason,omitempty"`
	RxMbps     float64 `json:"rxMbps"`
	RxPps      float64 `json:"rxPps"`
	CPU        float64 `json:"cpu"`
	MonthUsed  float64 `json:"monthUsedGB"`
	MonthLimit float64 `json:"monthLimitGB,omitempty"`
}

// monthUsage is this month's transfer total, persisted to disk.
type monthUsage struct {
	Month string `json:"month"` // "2026-10" in -month-tz
	Bytes uint64 `json:"bytes"`
}

func loadUsage(path string) monthUsage {
	var u monthUsage
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &u)
	}
	return u
}

func saveUsage(path string, u monthUsage) {
	data, _ := json.Marshal(u)
	tmp := path + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, path)
	}
}

func main() {
	addr := flag.String("addr", ":9478", "listen address")
	iface := flag.String("iface", "eth0", "public network interface")
	maxMbps := flag.Float64("max-rx-mbps", 400, "inbound bandwidth that counts as overloaded")
	maxPps := flag.Float64("max-rx-pps", 60000, "inbound packets/second that counts as overloaded")
	maxCPU := flag.Float64("max-cpu", 80, "CPU percent that counts as overloaded")
	trip := flag.Int("trip", 3, "seconds above a threshold before reporting overloaded")
	clear := flag.Int("clear", 60, "seconds comfortably below every threshold before clearing")
	limitGB := flag.Float64("monthly-limit-gb", 0, "host's monthly transfer allowance in GB (0 = don't track)")
	threshold := flag.Float64("monthly-threshold", 0.9, "fraction of the allowance at which to report overloaded")
	count := flag.String("monthly-count", "both", "what the host counts: both, tx (upload) or rx (download)")
	monthTZ := flag.String("month-tz", "Australia/Brisbane", "time zone the host's billing month follows")
	stateDir := flag.String("state-dir", "/var/lib/turnload", "where the monthly total is kept")
	seedGB := flag.Float64("seed-used-gb", 0, "usage so far this month, used only when there's no saved total for it")
	flag.Parse()

	loc, err := time.LoadLocation(*monthTZ)
	if err != nil {
		log.Fatalf("turnload: -month-tz: %v", err)
	}
	usagePath := *stateDir + "/usage.json"
	thisMonth := func() string { return time.Now().In(loc).Format("2006-01") }
	usage := loadUsage(usagePath)
	if usage.Month != thisMonth() {
		usage = monthUsage{Month: thisMonth(), Bytes: uint64(*seedGB * 1e9)}
	}
	lastSave := time.Now()
	rateOverloaded, rateReason := false, ""

	var mu sync.Mutex
	cur := status{}
	go func() {
		prev, err := read(*iface)
		if err != nil {
			log.Fatalf("turnload: %v", err)
		}
		above, below := 0, 0
		for range time.Tick(time.Second) {
			next, err := read(*iface)
			if err != nil {
				log.Printf("turnload: %v", err)
				continue
			}
			// Monthly total (counters only grow while we run, so a plain delta).
			if *limitGB > 0 {
				var delta uint64
				switch *count {
				case "tx":
					delta = grew(prev.txBytes, next.txBytes)
				case "rx":
					delta = grew(prev.rxBytes, next.rxBytes)
				default:
					delta = grew(prev.rxBytes, next.rxBytes) + grew(prev.txBytes, next.txBytes)
				}
				if m := thisMonth(); m != usage.Month {
					log.Printf("turnload: new month %s (last month used %.1f GB)", m, float64(usage.Bytes)/1e9)
					usage = monthUsage{Month: m}
					saveUsage(usagePath, usage)
				}
				usage.Bytes += delta
				if time.Since(lastSave) > 30*time.Second {
					saveUsage(usagePath, usage)
					lastSave = time.Now()
				}
			}
			mbps := float64(grew(prev.rxBytes, next.rxBytes)) * 8 / 1e6
			pps := float64(grew(prev.rxPackets, next.rxPackets))
			cpu := 0.0
			if dt := next.cpuTotal - prev.cpuTotal; dt > 0 {
				cpu = 100 * float64(next.cpuBusy-prev.cpuBusy) / float64(dt)
			}
			prev = next

			reason := ""
			switch {
			case mbps > *maxMbps:
				reason = fmt.Sprintf("inbound %.0f Mbps", mbps)
			case pps > *maxPps:
				reason = fmt.Sprintf("inbound %.0f packets/s", pps)
			case cpu > *maxCPU:
				reason = fmt.Sprintf("CPU %.0f%%", cpu)
			}
			calm := mbps < 0.7**maxMbps && pps < 0.7**maxPps && cpu < 0.7**maxCPU
			if reason != "" {
				above++
				below = 0
			} else {
				above = 0
				if calm {
					below++
				} else {
					below = 0
				}
			}

			switch {
			case !rateOverloaded && above >= *trip:
				rateOverloaded, rateReason = true, reason
				log.Printf("turnload: overloaded (%s)", reason)
			case rateOverloaded && below >= *clear:
				rateOverloaded, rateReason = false, ""
				log.Printf("turnload: back to normal")
			case rateOverloaded && reason != "":
				rateReason = reason
			}
			usedGB := float64(usage.Bytes) / 1e9
			quotaHit := *limitGB > 0 && usedGB >= *threshold**limitGB

			mu.Lock()
			wasQuota := cur.Overloaded && strings.HasPrefix(cur.Reason, "monthly")
			cur.RxMbps, cur.RxPps, cur.CPU = round1(mbps), round1(pps), round1(cpu)
			cur.MonthUsed, cur.MonthLimit = round1(usedGB), *limitGB
			switch {
			case rateOverloaded:
				cur.Overloaded, cur.Reason = true, rateReason
			case quotaHit:
				cur.Overloaded = true
				cur.Reason = fmt.Sprintf("monthly data %.0f of %.0f GB used", usedGB, *limitGB)
				if !wasQuota {
					log.Printf("turnload: %s; reporting overloaded until next month", cur.Reason)
				}
			default:
				cur.Overloaded, cur.Reason = false, ""
			}
			mu.Unlock()
		}
	}()

	http.HandleFunc("/status", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		st := cur
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(st)
	})
	srv := &http.Server{Addr: *addr, ReadHeaderTimeout: 2 * time.Second, WriteTimeout: 2 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func round1(f float64) float64 { return float64(int64(f*10+0.5)) / 10 }

func read(iface string) (sample, error) {
	var s sample
	f, err := os.Open("/proc/net/dev")
	if err != nil {
		return s, err
	}
	defer f.Close()
	found := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		name, rest, ok := strings.Cut(strings.TrimSpace(sc.Text()), ":")
		if !ok || strings.TrimSpace(name) != iface {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) < 2 {
			break
		}
		s.rxBytes, _ = strconv.ParseUint(fields[0], 10, 64)
		s.rxPackets, _ = strconv.ParseUint(fields[1], 10, 64)
		if len(fields) > 8 {
			s.txBytes, _ = strconv.ParseUint(fields[8], 10, 64)
		}
		found = true
	}
	if !found {
		return s, fmt.Errorf("interface %q not in /proc/net/dev", iface)
	}
	stat, err := os.ReadFile("/proc/stat")
	if err != nil {
		return s, err
	}
	line, _, _ := strings.Cut(string(stat), "\n")
	fields := strings.Fields(line) // cpu user nice system idle iowait irq softirq steal guest guest_nice
	if len(fields) < 5 || fields[0] != "cpu" {
		return s, fmt.Errorf("unexpected /proc/stat")
	}
	// The first eight counters: guest and guest_nice are already included in
	// user and nice, so adding them would count that time twice.
	counters := fields[1:]
	if len(counters) > 8 {
		counters = counters[:8]
	}
	for i, v := range counters {
		n, _ := strconv.ParseUint(v, 10, 64)
		s.cpuTotal += n
		if i != 3 && i != 4 { // idle, iowait
			s.cpuBusy += n
		}
	}
	return s, nil
}

// grew is how much a NIC counter rose. A counter that went backwards (driver
// reload, interface re-created, 32-bit wrap) counts as zero rather than an
// unsigned underflow that would read as exabytes and pin failover for the month.
func grew(prev, next uint64) uint64 {
	if next < prev {
		return 0
	}
	return next - prev
}
