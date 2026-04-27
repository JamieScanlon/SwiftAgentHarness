// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentHarness",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "SwiftAgentHarness",
            targets: ["SwiftAgentHarness"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/JamieScanlon/SwiftAgentKit.git",
            from: "0.14.0"
        ),
    ],
    targets: [
        .target(
            name: "SwiftAgentHarness",
            dependencies: [
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
            ]
        ),
        .testTarget(
            name: "SwiftAgentHarnessTests",
            dependencies: ["SwiftAgentHarness"]
        ),
    ]
)
