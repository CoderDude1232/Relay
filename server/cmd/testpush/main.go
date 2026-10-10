// testpush sends a single APNs notification to a device token, for
// diagnosing the push path end-to-end without going through the relay's
// offline detection. The payload carries junk in place of an envelope, so
// the NSE fails to decode and shows the generic "New message" banner, which
// is enough to confirm delivery and on-device display.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/relayapp/relay-server/internal/apns"
	"github.com/relayapp/relay-server/internal/privlog"
)

func main() {
	token := flag.String("token", "", "hex APNs device token")
	keyPath := flag.String("apns-key", "", "path to .p8")
	keyID := flag.String("apns-key-id", "", "APNs key id")
	teamID := flag.String("apns-team-id", "", "team id")
	topic := flag.String("apns-topic", "app.relaymsg", "bundle id")
	production := flag.Bool("apns-production", false, "use production host")
	flag.Parse()

	p, err := apns.New(*keyPath, *keyID, *teamID, *topic, *production)
	if err != nil {
		fmt.Println("setup error:", privlog.Error(err))
		os.Exit(1)
	}
	if err := p.Push(*token, []byte("diagnostic")); err != nil {
		fmt.Println("PUSH FAILED:", privlog.Error(err))
		os.Exit(1)
	}
	fmt.Println("push accepted by APNs")
}
