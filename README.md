# SwiftAgentHarness

SwiftAgentHarness is a Swift 6 library for building production agent harnesses: the infrastructure that turns an LLM into a long-running, tool-using agent that can hold many conversations at once. It implements the [Agent Harness Best-Practice Template](./harness-template/README.md), a design guide included in this repository that draws on a study of six production open-source harnesses. The template explains why each layer exists, and this package provides a tested implementation of each one. It covers model routing and failover, a sandboxed tool system, sub-agent delegation, context compaction, persistent memory, and an HTTP/WebSocket gateway that any client (a TUI, a web app, a chat bridge) can drive over the same contract.

## Overview

The source tree mirrors the template's architecture: eight core layers, plus the backends they drive, the surfaces that consume them, and the cross-cutting concerns that span them.

- **Core layers** (`Sources/SwiftAgentHarness/Core`)
  - **Model Pool:** a model registry with capability queries, failover, budgets, cost accounting, and prompt-cache planning.
  - **Tool System:** the only path to side effects. It covers filesystem and shell tools, approvals, MCP tools, skills, and slash commands.
  - **Sub-Agent Pool:** delegation to child agents in process, over A2A, or over ACP.
  - **Context Engine:** builds each turn's request through system-prompt assembly, history trimming, compaction, and memory injection.
  - **Memory:** project-instruction files and memory the agent writes itself.
  - **Agent Runtime:** the inner loop.
  - **Conversation Manager:** persistent, branchable conversations.
  - **Communication Layer:** a versioned HTTP control plane and WebSocket data plane, specified in [`openapi/`](./openapi/).
- **Backends:** model providers, persistence (SwiftData catalog plus JSONL transcripts), sandboxed execution environments, and computer-use display targets.
- **Surfaces:** client interfaces and non-interactive triggers such as schedules, webhooks, and channel messages, each labeled with how far its input can be trusted.

The package ships three library products:

| Product | Purpose |
|---|---|
| `SwiftAgentHarness` | The harness itself. It registers no providers by default. |
| `SwiftAgentHarnessProviders` | Bundled provider plugins for OpenAI, Anthropic, Ollama, LM Studio, OpenRouter, and any OpenAI-compatible endpoint. |
| `SwiftAgentHarnessComputerUseMac` | The macOS computer-use driver, built on ScreenCaptureKit, Accessibility, and input events. |

## Requirements

- Swift 6.0 or later
- Deployment targets: **macOS 15+**, **iOS 18+**, **visionOS 2+**

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
        from: "1.1.0"
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
- [Decision models](./docs/DECISION_MODELS.md) — every way the harness uses deciders (tool-call gatekeeper, memory write gate, skill pre-filter, guardrails, injection probe, model routing, your own decisions), the shared setup, and per-use-case details.
- [Computer use](./docs/COMPUTER_USE.md) — display targets, leases and tiered grants, per-action gating and intent checks, budgets and takeover, and the `computer_*` tool family.

The design rationale for every layer lives in the [Agent Harness Best-Practice Template](./harness-template/README.md), included in this repository under [`harness-template/`](./harness-template/).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md). All contributors must sign the [Contributor License Agreement](./CLA.md) (a one-time electronic signature on your first pull request), which enables the project's dual-licensing model.

## License

SwiftAgentHarness is dual-licensed:

- **Open source:** [GNU Affero General Public License v3](./LICENSE) — free to use, modify, and distribute under the AGPL's terms, including its network-use provisions.
- **Commercial:** for use cases the AGPL doesn't fit (e.g., proprietary products or services that cannot comply with AGPL obligations), commercial licenses are available from the project owner. Contact [jamie@tenthlettermade.com](mailto:jamie@tenthlettermade.com).
