// swift-tools-version: 6.2
import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "PadServerCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "PadDomain", targets: ["PadDomain"]),
        .library(name: "PadApplication", targets: ["PadApplication"]),
        .library(name: "PadInterface", targets: ["PadInterface"]),
        .library(name: "PadInfrastructure", targets: ["PadInfrastructure"]),
        .library(name: "PadTestSupport", targets: ["PadTestSupport"])
    ],
    dependencies: [
        // Hummingbird 2.27.1 は swift-distributed-tracing 1.6.0 でビルドできないため, issue 922 の修正後に削除する.
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", "1.3.0"..<"1.6.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")
    ],
    targets: [
        .target(name: "PadDomain", swiftSettings: commonSwiftSettings),
        .target(name: "PadApplication", dependencies: ["PadDomain"], swiftSettings: commonSwiftSettings),
        .target(name: "PadInterface", dependencies: ["PadApplication", "PadDomain"], swiftSettings: commonSwiftSettings),
        .target(
            name: "PadInfrastructure",
            dependencies: [
                "PadApplication",
                "PadDomain",
                .product(name: "Hummingbird", package: "hummingbird")
            ],
            swiftSettings: commonSwiftSettings
        ),
        .target(name: "PadTestSupport", dependencies: ["PadApplication", "PadDomain"], swiftSettings: commonSwiftSettings),
        .testTarget(name: "PadDomainTests", dependencies: ["PadDomain", "PadTestSupport"], swiftSettings: commonSwiftSettings),
        .testTarget(name: "PadApplicationTests", dependencies: ["PadApplication", "PadDomain", "PadTestSupport"], swiftSettings: commonSwiftSettings),
        .testTarget(name: "PadInterfaceTests", dependencies: ["PadInterface", "PadApplication", "PadDomain", "PadTestSupport"], swiftSettings: commonSwiftSettings),
        .testTarget(name: "PadInfrastructureTests", dependencies: ["PadInfrastructure", "PadApplication", "PadDomain", "PadTestSupport"], swiftSettings: commonSwiftSettings)
    ],
    swiftLanguageModes: [.v6]
)
