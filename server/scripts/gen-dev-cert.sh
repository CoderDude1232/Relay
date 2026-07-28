#!/bin/sh
# Generates a self-signed TLS certificate for the DEVELOPMENT relay and
# prints the SPKI pin the iOS client must trust.
#
# The cert is EC P-256, valid 10 years, with SANs for this Mac's LAN IP (so
# the iPhone can connect over Wi-Fi), 127.0.0.1 and localhost. The client
# pins the public key (SPKI SHA-256), so regenerating with the SAME key
# keeps the pin stable; a fresh key means updating RelayTLS.devPins.
#
# Usage: sh gen-dev-cert.sh [lan-ip]
set -eu

DIR="$HOME/.relay-dev"
CRT="$DIR/relayd.crt"
KEY="$DIR/relayd.key"
mkdir -p "$DIR"

IP="${1:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"
echo "Using LAN IP: $IP"

# Reuse the existing key if present so the SPKI pin stays stable across
# regenerations; otherwise create a fresh P-256 key.
if [ ! -f "$KEY" ]; then
    openssl ecparam -name prime256v1 -genkey -noout -out "$KEY"
    echo "generated new key: $KEY"
else
    echo "reusing existing key: $KEY (pin unchanged)"
fi

openssl req -x509 -new -nodes -key "$KEY" -sha256 -days 3650 \
    -subj "/CN=relay-dev" \
    -addext "subjectAltName=IP:$IP,IP:127.0.0.1,DNS:localhost" \
    -out "$CRT"

PIN="$(openssl x509 -in "$CRT" -pubkey -noout \
    | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary \
    | openssl base64)"

echo ""
echo "cert: $CRT"
echo "key:  $KEY"
echo "SPKI pin (base64 SHA-256) -> put in RelayTLS.devPins:"
echo "    $PIN"
