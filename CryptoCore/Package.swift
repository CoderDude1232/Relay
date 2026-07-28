// swift-tools-version:6.0
import Foundation
import PackageDescription

// The prebuilt Rust core (libsignal_ffi.a) is linked by whoever produces
// the final binary. The app target does it via LIBRARY_SEARCH_PATHS; the
// test bundle here needs the simulator build passed explicitly.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "CryptoCore",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "CryptoCore", targets: ["CryptoCore"])
    ],
    dependencies: [
        .package(name: "LibSignalClient", path: "../third_party/libsignal/swift")
    ],
    targets: [
        .target(
            name: "CryptoCore",
            dependencies: [
                .product(name: "LibSignalClient", package: "LibSignalClient")
            ]
        ),
        .testTarget(
            name: "CryptoCoreTests",
            dependencies: ["CryptoCore"],
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/../third_party/libsignal-ffi/ios-simulator"])
            ]
        ),
    ]
)
