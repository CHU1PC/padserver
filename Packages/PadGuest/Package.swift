// swift-tools-version: 6.2
import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "PadGuest",
    products: [
        .library(name: "PadGuest", targets: ["PadGuest"])
    ],
    targets: [
        .target(name: "PadGuest", swiftSettings: commonSwiftSettings),
        .testTarget(name: "PadGuestTests", dependencies: ["PadGuest"], swiftSettings: commonSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
