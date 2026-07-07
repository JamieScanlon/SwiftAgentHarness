# SwiftAgentHarness Overview

SwiftAgentHarness is a Swift 6 library for building production agentic harnesses — the infrastructure that turns an LLM into a long-running, tool-using, multi-conversation agent. It is the reference implementation of the [Agent Harness Best-Practice Template](../harness-template/README.md), a prescriptive architecture guide included in this repository under [`harness-template/`](../harness-template/). Where the template explains *why* each layer exists and what shape it should take, this package is a concrete, tested Swift implementation of that design.

It builds on [SwiftAgentKit](https://github.com/JamieScanlon/SwiftAgentKit) for the underlying agent primitives (MCP, A2A, provider clients).

## What you get

A harness, not a chatbot wrapper. Concretely:

- **Multi-conversation runtime** with persistent transcripts, branching, in-place revert, compaction, and cross-session search.
- **Model Pool** — models (not providers) as the base abstraction: registry, capability query, failover, budget accounting, cost ledger, prompt-cache planning.
- **Tool System** — the single sanctioned path to side effects: workspace filesystem tools, sandboxed shell execution, approval flows, MCP-provided tools, skills, slash commands.
- **Sub-Agent Pool** — delegate work to child agents (in-process, A2A, or ACP) through one spawn/completion contract with lane-aware scheduling.
- **Context Engine** — per-turn projection of the transcript: system-prompt assembly, history trimming, LLM compaction with deterministic hygiene passes, memory injection.
- **Memory** — project-instruction files plus agent-written memory with recall selection.
- **Communication Layer** — a versioned HTTP control plane and WebSocket data plane (see [`openapi/openapi.yaml`](../openapi/openapi.yaml) and [`openapi/asyncapi.yaml`](../openapi/asyncapi.yaml)) so any client — TUI, web app, channel bridge — talks to the harness over the same contract.
- **Surfaces** — a TUI toolkit and trigger surface (scheduling, webhooks, channel arrivals) with trust-classified input provenance.

## Package layout

The source tree mirrors the template's architecture one-to-one:

| Path | Template topic |
|---|---|
| `Sources/SwiftAgentHarness/Core/ModelPool` | [Model Pool](../harness-template/core/model-pool/README.md) |
| `Sources/SwiftAgentHarness/Core/SubAgentPool` | [Sub-Agent Pool](../harness-template/core/sub-agent-pool/README.md) |
| `Sources/SwiftAgentHarness/Core/ToolSystem` | [Tool System](../harness-template/core/tool-system/README.md) |
| `Sources/SwiftAgentHarness/Core/ContextEngine` | [Context Engine](../harness-template/core/context-engine/README.md) |
| `Sources/SwiftAgentHarness/Core/Memory` | [Memory](../harness-template/core/memory/README.md) |
| `Sources/SwiftAgentHarness/Core/AgentRuntime` | [Agent Runtime](../harness-template/core/agent-runtime/README.md) (the inner loop) |
| `Sources/SwiftAgentHarness/Core/ConversationManager` | [Conversation Manager](../harness-template/core/conversation-manager/README.md) |
| `Sources/SwiftAgentHarness/Core/CommunicationLayer` | [Communication Layer](../harness-template/core/communication-layer/README.md) |
| `Sources/SwiftAgentHarness/Backends/{Providers,Persistence,ExecutionEnvironments}` | [Providers](../harness-template/backends/providers/README.md) / [Persistence](../harness-template/backends/persistence/README.md) / [Execution Environments](../harness-template/backends/execution-environments/README.md) |
| `Sources/SwiftAgentHarness/Surfaces/{Interface,Triggers}` | [Interface](../harness-template/surfaces/interface/README.md) / [Triggers](../harness-template/surfaces/triggers/README.md) |
| `Sources/SwiftAgentHarness/Cross-Cutting` | [Extensibility](../harness-template/cross-cutting/extensibility/README.md) / [Observability](../harness-template/cross-cutting/observability/README.md) |
| `Sources/SwiftAgentHarnessProviders` | Bundled provider plugins |

## The two products

- **`SwiftAgentHarness`** — the harness itself. No providers are registered by default.
- **`SwiftAgentHarnessProviders`** — bundled provider plugins (OpenAI, Anthropic, Ollama, LM Studio, OpenRouter, and a generic OpenAI-compat adapter for any local endpoint). Link it and call `SwiftAgentHarnessProviders.bootstrap()` once at startup, or supply your own providers through `ProviderRegistry`.

## Key entry-point types

- **`HarnessRuntimeSession`** — the composition root's main artifact: an actor owning the conversation domain, agent runtime, sub-agent services, and persistence for one harness process. Built with `HarnessRuntimeSession.makeProduction(...)`.
- **`APILayer`** — the gateway server (HTTP + WebSocket). Wire it to a session via `SplitGatewayServiceFactory` and call `start()`.
- **`ModelManager` / `ProviderRegistry` / `AuthProfileStore`** — model catalog, provider plugins, and credential profiles.
- **`ConversationPersistenceDomain`** — SwiftData-backed catalog plus JSONL transcript persistence.

See [QUICKSTART.md](./QUICKSTART.md) for the minimal wiring.

## Requirements

Swift 6.0+, strict concurrency. macOS 13+, iOS 16+, visionOS 1+.
