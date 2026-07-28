#!/bin/sh
# Regenerates Go protobuf code from the shared schema in ../proto.
# Requires protoc and protoc-gen-go on PATH.
set -eu
cd "$(dirname "$0")/.."
protoc --proto_path=../proto \
    --go_out=gen --go_opt=module=github.com/relayapp/relay-server/gen \
    ../proto/relay.proto ../proto/content.proto
echo "generated: gen/relaypb gen/contentpb"
