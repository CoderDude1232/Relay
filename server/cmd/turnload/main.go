// Command turnload runs on the TURN box and reports whether it is close to its
// limits, so relayd can move new calls to the backup TURN service *before*
// coturn or the host is overwhelmed.
//
// It samples /proc every second: inbound bandwidth and packet rate on the
// public interface, and CPU use. "Overloaded" is any of them above its
// threshold for -trip consecutive seconds; it clears only after -clear
// consecutive seconds below 70% of every threshold (hysteresis, so calls
// don't bounce between providers).
//
// GET /status → {"overloaded":bool,"reason":"...","rxMbps":..,"rxPps":..,"cpu":..}
// Serve it only to the relay host (firewall), it's not sensitive but needn't
// be public.
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
	rxBytes, rxPackets uint64
	cpuBusy, cpuTotal  uint64
}

type status struct {
	Overloaded bool    `json:"overloaded"`
	Reason     string  `json:"reason,omitempty"`
	RxMbps     float64 `json:"rxMbps"`
	RxPps      float64 `json:"rxPps"`
	CPU        float64 `json:"cpu"`
}

func main() {
	addr := flag.String("addr", ":9478", "listen address")
	iface := flag.String("iface", "eth0", "public network interface")
	maxMbps := flag.Float64("max-rx-mbps", 400, "inbound bandwidth that counts as overloaded")
	maxPps := flag.Float64("max-rx-pps", 60000, "inbound packets/second that counts as overloaded")
	maxCPU := flag.Float64("max-cpu", 80, "CPU percent that counts as overloaded")
	trip := flag.Int("trip", 3, "seconds above a threshold before reporting overloaded")
	clear := flag.Int("clear", 60, "seconds comfortably below every threshold before clearing")
	flag.Parse()

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
			mbps := float64(next.rxBytes-prev.rxBytes) * 8 / 1e6
			pps := float64(next.rxPackets - prev.rxPackets)
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

			mu.Lock()
			cur.RxMbps, cur.RxPps, cur.CPU = round1(mbps), round1(pps), round1(cpu)
			switch {
			case !cur.Overloaded && above >= *trip:
				cur.Overloaded, cur.Reason = true, reason
				log.Printf("turnload: overloaded (%s)", reason)
			case cur.Overloaded && below >= *clear:
				cur.Overloaded, cur.Reason = false, ""
				log.Printf("turnload: back to normal")
			case cur.Overloaded && reason != "":
				cur.Reason = reason
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
	fields := strings.Fields(line) // cpu user nice system idle iowait irq softirq steal ...
	for i, v := range fields[1:] {
		n, _ := strconv.ParseUint(v, 10, 64)
		s.cpuTotal += n
		if i != 3 && i != 4 { // idle, iowait
			s.cpuBusy += n
		}
	}
	return s, nil
}
