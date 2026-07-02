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
        .library(
            name: "SwiftAgentHarnessProviders",
            targets: ["SwiftAgentHarnessProviders"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/JamieScanlon/SwiftAgentKit.git", from: "0.19.0"),
        // .package(url: "https://github.com/JamieScanlon/SwiftAgentKit.git", revision: "59f20badfafea33a71150445e6e1e55f273eca93"),
        .package(url: "https://github.com/JamieScanlon/OllamaKit.git", from: "1.0.8"),
    //    .package(url: "https://github.com/JamieScanlon/OllamaKit.git", revision: "56f78f94c1684bffd2bf61d62f4eb539cd04645f"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
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
                .product(name: "JWTKit", package: "jwt-kit"),
            ],
            resources: [
                .process("Backends/ExecutionEnvironments/manifests"),
            ]
        ),
        .target(
            name: "SwiftAgentHarnessProviders",
            dependencies: [
                "SwiftAgentHarness",
                .product(name: "OllamaKit", package: "OllamaKit"),
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
            ],
            resources: [
                .process("manifests"),
                .process("catalogs"),
            ]
        ),
        .testTarget(
            name: "SwiftAgentHarnessTests",
            dependencies: [
                "SwiftAgentHarness",
                "SwiftAgentHarnessProviders",
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
