# Agent Harness Best-Practice Template

Prescriptive recommendations for building a production-quality agentic harness. Each topic page leads with a recommended approach, then describes alternatives worth knowing about and the constraints under which each is the better fit.

The recommendations were synthesized from a comparative study of six production open-source agentic harnesses (referred to throughout as "the reference harnesses" or "the six harnesses"), plus the public behavior of several commercial agents. Pages describe patterns generically rather than attributing them to specific projects; where a pattern appears in only one or two of the studied harnesses, the text says so.

## Topics

This template is organized to mirror the architecture itself: the inner ring of eight peer layers, plus the three auxiliary buckets — backends the inner ring drives, surfaces that consume it, and cross-cutting concerns that hook across it. See [`./core/`](./core/) for the spine doc that captures this structure in detail, including the framing distinction between **tool invocations** (anything the model invokes via a tool call — function tools, sub-agent delegation, Skill loads, MCP-provided tools, agent-driven memory recall) and **context resources** (what the model consumes but doesn't invoke — system prompt, prior turns, auto-loaded memory).

### Inner ring — the eight core layers

| Layer | Summary |
|---|---|
| [Core (spine)](./core/) | Eight-layer ring + three-Pool pattern + tool-call-vs-context-resource framing + auxiliary taxonomy. The page every other topic references. |
| [Model Pool](./core/model-pool/) | Models-not-providers as base abstraction; registry, capability query, scheduler, lifecycle, failover, budget, cache. |
| [Sub-Agent Pool](./core/sub-agent-pool/) | One abstraction over internal + remote (A2A / ACP-stdio / custom) delegation. Practical patterns in `./agent-orchestration.md`. |
| [Tool System](./core/tool-system/) | The single sanctioned path to side-effects, and the dispatch fabric for every model-invokable resource (function tools, sub-agent delegates, Skill loads, MCP-provided tools, agent-driven memory recall). Hosts the Tools and Skills registries. |
| [Context Engine](./core/context-engine/) | What gets sent to the model on each turn. Compaction + summarization + memory injection + system-prompt assembly via a defined lifecycle. |
| [Memory](./core/memory/) | Cross-session knowledge: project-instruction files, agent-written memory, taxonomies, recall, drift, consolidation. The one persistent resource the Context Engine auto-loads from on every turn without model invocation. |
| [Agent Runtime](./core/agent-runtime/) | The inner loop. Stateless, takes a conversation, emits events. Kept dumb on purpose. |
| [Conversation Manager](./core/conversation-manager/) | Conversation as a first-class resource: CRUD, branching, mode, attached resources, lifecycle. Owns the message log; sub-agents are nested conversations. Siblings: [modes.md](./core/conversation-manager/modes.md) (`ModeProfile` / `ModeRegistry` design) and [runs.md](./core/conversation-manager/runs.md) (runs as a derived view, cross-layer cancellation contract, explicit out-of-scope decision on deliberate pause/resume). |
| [Communication Layer](./core/communication-layer/) | Wire protocol. Control plane (HTTP) / data plane (WebSocket multiplexed by topic). Reconcile-and-watch + seq + replay. |

### Backends — drivers the inner ring uses

| Backend | Summary |
|---|---|
| [Providers](./backends/providers/) | Provider adapters under the Model Pool: plugin shape, manifest, capability scope, auth profiles, wire codec, tool/prompt normalization. |
| [Persistence](./backends/persistence/) | Session storage, branching, transcript archiving, cross-session search. Backend driver for the Conversation Manager and Memory. |
| [Execution Environments](./backends/execution-environments/) | Process-host backends under the Tool System: backend registry, `SandboxBackendHandle` contract, mode/scope/backend factoring, FS bridge, path policy, long-running processes, escape hatches. |

### Surfaces — clients of the Communication Layer

| Surface | Summary |
|---|---|
| [Interface](./surfaces/interface/) | The uniform Surface contract: capability-typed plugin over the Comm Layer; one shared output tool, portable `MessagePresentation` + core-owned fallback, surface-native input; streaming granularity as a capability ladder; liveness; approval delivery vs classification; agent-driven UI; voice slots; personality. |
| [Triggers](./surfaces/triggers/) | Non-interactive activation: cron, webhooks, channel arrivals, file-events, plus the trust-classification machinery for non-user content. |

### Cross-cutting — hook points that span layers

| Concern | Summary |
|---|---|
| [Extensibility](./cross-cutting/extensibility/) | The plugin/hook host across the inner ring: capability-typed plugin records over an ABC, manifest-first validation, two distinct hook systems (operator `HOOK.md` vs in-process SDK hooks), multi-bundle loader (native/Codex/Claude/Cursor) that maps content without importing code, MCP as both client and server, and registry-owned packaging/trust. Slash commands broken out as a standalone topic: [`slash-commands.md`](./cross-cutting/extensibility/slash-commands.md). |
| [Observability](./cross-cutting/observability/) | Logs, structured events, traces, and cost/usage metrics across three signal planes: the event bus as in-conversation audit log, an out-of-band logger for infra/crash signal, and an OTel-shaped trace/metric overlay. Canonical usage shape + computed-once cost, W3C `traceparent` propagation across the three Pools, redaction at the emit boundary, exporters via extensibility hooks, operator stream vs curated `/usage` surfaces. |

## How to read a topic page

Each leaf page follows the same shape:

- **TL;DR** — the recommended approach in one or two sentences.
- **Recommendation** — the prescriptive design, with rationale.
- **Alternatives** — variants worth knowing about, with the constraints under which each is the better choice.
- **Anti-patterns** — designs that tend not to work well, with reasoning.
