# SwiftAgentHarness

A modern implementation of an Agent Harness written in Swift.

## Requirements

- Swift 5.9 or later
- Deployment targets: **macOS 13+**, **iOS 16+**, **visionOS 1+**

## Installation

### Swift Package Manager (package dependency)

Add SwiftAgentHarness to the `dependencies` array in your `Package.swift`, then link the product to your target.

**From a published repository** (after you have a Git URL and tag or branch):

```swift
dependencies: [
    .package(
        url: "https://github.com/YourOrg/SwiftAgentHarness.git",
        from: "0.0.1"
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

Then use the public APIs exported by the `SwiftAgentHarness` module.
