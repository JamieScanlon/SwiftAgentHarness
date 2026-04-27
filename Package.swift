// swift-tools-version: 5.9
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
    targets: [
        .target(
            name: "SwiftAgentHarness"
        ),
        .testTarget(
            name: "SwiftAgentHarnessTests",
            dependencies: ["SwiftAgentHarness"]
        ),
    ]
)
