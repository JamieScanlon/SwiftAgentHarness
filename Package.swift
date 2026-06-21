// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentHarness",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2)
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
        .package(url: "https://github.com/JamieScanlon/OllamaKit.git", from: "1.0.8"),
    //    .package(url: "https://github.com/JamieScanlon/OllamaKit.git", revision: "56f78f94c1684bffd2bf61d62f4eb539cd04645f"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
    ],
    targets: [
        .target(
            name: "SwiftAgentHarness",
            dependencies: [
                .product(name: "OllamaKit", package: "OllamaKit"),
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitOrchestrator", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitSkills", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitMCP", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitA2A", package: "SwiftAgentKit"),
            ],
            resources: [
                .process("Backends/ExecutionEnvironments/manifests"),
            ]
        ),
        .testTarget(
            name: "SwiftAgentHarnessTests",
            dependencies: [
                "SwiftAgentHarness",
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitOrchestrator", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitSkills", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitMCP", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitA2A", package: "SwiftAgentKit"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            resources: [
                .copy("Resources/PromptConfig.json"),
            ]
        ),
    ]
)
