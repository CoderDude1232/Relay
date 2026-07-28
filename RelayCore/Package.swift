// swift-tools-version:6.0
import Foundation
import PackageDescription

// Application core shared by the app target and the Notification Service
// Extension: the one place that turns an incoming envelope into stored state
// + a notification, so both processes decrypt identically. See
// CryptoCore/Package.swift for why test bundles link libsignal_ffi.a directly.
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
