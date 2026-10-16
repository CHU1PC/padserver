// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "padctl",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "padctl", targets: ["padctl"])
    ],
    dependencies: [
        .package(path: "../Packages/PadServerCore"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        // TOMLDecoder は 0.x のため, API 変更に備えて次の minor までに固定する.
        .package(url: "https://github.com/dduan/TOMLDecoder.git", .upToNextMinor(from: "0.4.5")),
    ],
    targets: [
        .executableTarget(
            name: "padctl",
            dependencies: [
                .product(name: "PadInterface", package: "PadServerCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "padctlTests",
            dependencies: ["padctl"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ],
    swiftLanguageModes: [.v6],
)
