// Standalone module so generating test vectors never modifies ../../../server.
// It only reads the relay's own generated protobuf types.
module relay/android/tools/genvectors

go 1.26.5

require (
	github.com/relayapp/relay-server v0.0.0
	google.golang.org/protobuf v1.36.11
)

replace github.com/relayapp/relay-server => ../../../server
