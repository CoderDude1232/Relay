// swift-tools-version:6.0
import Foundation
import PackageDescription

// Shared by the app and the Notification Service Extension so both turn an
// incoming envelope into stored state and a notification the same way.
// Test bundles link libsignal_ffi.a explicitly; see CryptoCore/Package.swift.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "RelayCore",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "RelayCore", targets: ["RelayCore"])
    ],
    dependencies: [
        .package(name: "CryptoCore", path: "../CryptoCore"),
        .package(name: "SecureStorage", path: "../SecureStorage"),
        .package(name: "RelayKit", path: "../RelayKit"),
        .package(name: "LibSignalClient", path: "../third_party/libsignal/swift"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
    ],
    targets: [
        .target(
            name: "RelayCore",
            dependencies: [
                .product(name: "CryptoCore", package: "CryptoCore"),
                .product(name: "SecureStorage", package: "SecureStorage"),
                .product(name: "RelayKit", package: "RelayKit"),
                .product(name: "LibSignalClient", package: "LibSignalClient"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ]
)
