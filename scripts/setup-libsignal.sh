#!/bin/sh
# Vendors libsignal for the iOS client. Run once after a fresh checkout.
#
# libsignal has no root Package.swift, so it can't be a remote SPM
# dependency. As Signal's CocoaPods integration does, this checks out the
# repo (the Swift package is in swift/) and downloads the prebuilt
# libsignal_ffi.a from Signal's artifact server. The Xcode project links it
# via per-SDK LIBRARY_SEARCH_PATHS.
set -eu

LIBSIGNAL_VERSION="v0.97.4"
ARCHIVE="libsignal-client-ios-build-${LIBSIGNAL_VERSION}.tar.gz"
ARCHIVE_URL="https://build-artifacts.signal.org/libraries/${ARCHIVE}"
ARCHIVE_SHA256="ef01dc615300fc2bb63559de6b8d2bbfd9798db459ef24b3b23ef224defaecee"

cd "$(dirname "$0")/.."
mkdir -p third_party
cd third_party

if [ ! -d libsignal ]; then
    git clone --depth 1 --branch "$LIBSIGNAL_VERSION" https://github.com/signalapp/libsignal.git
else
    echo "third_party/libsignal already present, skipping clone"
fi

if [ ! -f libsignal-ffi/ios-device/libsignal_ffi.a ]; then
    curl -L -o "$ARCHIVE" "$ARCHIVE_URL"
    echo "${ARCHIVE_SHA256}  ${ARCHIVE}" | shasum -a 256 -c -
    tar -xzf "$ARCHIVE"
    mkdir -p libsignal-ffi/ios-device libsignal-ffi/ios-simulator
    cp target/aarch64-apple-ios/release/libsignal_ffi.a libsignal-ffi/ios-device/
    lipo -create \
        target/aarch64-apple-ios-sim/release/libsignal_ffi.a \
        target/x86_64-apple-ios/release/libsignal_ffi.a \
        -output libsignal-ffi/ios-simulator/libsignal_ffi.a
    rm -rf target "$ARCHIVE"
else
    echo "third_party/libsignal-ffi already present, skipping download"
fi

echo "libsignal ${LIBSIGNAL_VERSION} vendored:"
lipo -info libsignal-ffi/ios-device/libsignal_ffi.a libsignal-ffi/ios-simulator/libsignal_ffi.a
