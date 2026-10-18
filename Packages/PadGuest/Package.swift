// swift-tools-version: 6.2
import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "PadGuest",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PadGuest", targets: ["PadGuest"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.1"),
    ],
    targets: [
        .target(
            name: "PadGuest",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: commonSwiftSettings),
        .testTarget(
            name: "PadGuestTests",
            dependencies: [
                "PadGuest",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: commonSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
