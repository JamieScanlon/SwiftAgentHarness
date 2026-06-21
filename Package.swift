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
        .package(url: "https://github.com/JamieScanlon/SwiftAgentKit.git",from: "0.16.0"),
        // .package(url: "https://github.com/JamieScanlon/SwiftAgentKit.git", revision: "bf5afdcdda00eb1f684c4d0c2cd0f4b597e7e374"),
    ],
    targets: [
        .target(
            name: "SwiftAgentHarness",
            dependencies: [
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitOrchestrator", package: "SwiftAgentKit"),
            ]
        ),
        .testTarget(
            name: "SwiftAgentHarnessTests",
            dependencies: [
                "SwiftAgentHarness",
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitOrchestrator", package: "SwiftAgentKit"),
            ]
        ),
    ]
)
