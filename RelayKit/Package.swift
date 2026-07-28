// swift-tools-version:6.0
import Foundation
import PackageDescription

// See CryptoCore/Package.swift — test bundles must link the prebuilt
// libsignal_ffi.a explicitly.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "RelayKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "RelayKit", targets: ["RelayKit"])
    ],
    dependencies: [
        .package(name: "CryptoCore", path: "../CryptoCore"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
    ],
    targets: [
        .target(
            name: "RelayKit",
            dependencies: [
                .product(name: "CryptoCore", package: "CryptoCore"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "RelayKitTests",
            dependencies: ["RelayKit"],
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/../third_party/libsignal-ffi/ios-simulator"])
            ]
        ),
    ]
)
