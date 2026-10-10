// swift-tools-version:6.0
import Foundation
import PackageDescription

// Test bundles link the prebuilt libsignal_ffi.a explicitly; see CryptoCore/Package.swift.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "SecureStorage",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "SecureStorage", targets: ["SecureStorage"])
    ],
    dependencies: [
        .package(name: "CryptoCore", path: "../CryptoCore"),
        .package(name: "LibSignalClient", path: "../third_party/libsignal/swift"),
        .package(url: "https://github.com/skiptools/swift-sqlcipher", from: "1.11.0"),
    ],
    targets: [
        .target(
            name: "SecureStorage",
            dependencies: [
                .product(name: "CryptoCore", package: "CryptoCore"),
                .product(name: "LibSignalClient", package: "LibSignalClient"),
                .product(name: "SQLCipher", package: "swift-sqlcipher"),
            ]
        ),
        .testTarget(
            name: "SecureStorageTests",
            dependencies: ["SecureStorage"],
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/../third_party/libsignal-ffi/ios-simulator"])
            ]
        ),
    ]
)
