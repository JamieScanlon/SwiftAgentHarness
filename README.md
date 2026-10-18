# SwiftAgentHarness

A modern implementation of an Agent Harness written in Swift.

## Requirements

- Swift 6.0 or later
- Deployment targets: **macOS 13+**, **iOS 16+**, **visionOS 1+**

## Dependencies

This package depends on **[SwiftAgentKit](https://github.com/JamieScanlon/SwiftAgentKit)**, a Swift framework for building AI agents (MCP, A2A, providers, and related tooling). SwiftPM resolves and links it automatically; you do not add SwiftAgentKit to your `Package.swift` unless you also import it directly in your app.

## Installation

### Swift Package Manager (package dependency)

Add SwiftAgentHarness to the `dependencies` array in your `Package.swift`, then link the product to your target.

**From a published repository** (after you have a Git URL and tag or branch):

```swift
dependencies: [
    .package(
        url: "https://github.com/JamieScanlon/SwiftAgentHarness.git",
        from: "1.0.0"
    ),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftAgentHarness", package: "SwiftAgentHarness"),
        ]
    ),
]
```

**From a local checkout** (for development or monorepos):

```swift
dependencies: [
    .package(path: "/path/to/SwiftAgentHarness"),
],
```

The package name is `SwiftAgentHarness`, so the `package:` label in `.product` must match that identifier.

### Xcode

1. Open your project or workspace.
2. **File** → **Add Package Dependencies…**
3. Enter the repository URL, or choose **Add Local…** and select this package folder.
4. Add the **SwiftAgentHarness** library to the app or framework target you need.

## Usage

```swift
import SwiftAgentHarness
```

Start with the docs:

- [Overview](./docs/OVERVIEW.md) — what SwiftAgentHarness is, the layer architecture, and the key entry-point types.
- [Quickstart](./docs/QUICKSTART.md) — register providers, build the composition root, start the gateway, and run a first conversation.

The design rationale for every layer lives in the [Agent Harness Best-Practice Template](./harness-template/README.md), included in this repository under [`harness-template/`](./harness-template/).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md). All contributors must sign the [Contributor License Agreement](./CLA.md) (a one-time electronic signature on your first pull request), which enables the project's dual-licensing model.

## License

SwiftAgentHarness is dual-licensed:

- **Open source:** [GNU Affero General Public License v3](./LICENSE) — free to use, modify, and distribute under the AGPL's terms, including its network-use provisions.
- **Commercial:** for use cases the AGPL doesn't fit (e.g., proprietary products or services that cannot comply with AGPL obligations), commercial licenses are available from the project owner. Contact [jamie@tenthlettermade.com](mailto:jamie@tenthlettermade.com).
