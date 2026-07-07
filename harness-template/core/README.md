# Core Architecture

The architectural spine of an agent harness — the layers every other topic in this template hangs off, and the boundaries between them.

This folder is different from the other topic folders. The others (`backends/`, `surfaces/`, `cross-cutting/`) each take one concern and recommend an approach. This folder defines *what the harness is* — the inner ring of layers, how they peer with each other, and where everything else slots in. The other topics reference this one for the layer their concern belongs to; this one reaches into them for the detailed designs.

## TL;DR

A harness has an **eight-layer inner ring**. Around it sit backends it drives, surfaces that consume it, and cross-cutting concerns that hook across it. The three "Pool" layers (Model Pool, Sub-Agent Pool, Tool System) are siblings — same registry / capability-query / lifecycle / transport-adapter shape. Memory is a peer layer alongside the Pools, the Context Engine, the Agent Runtime, the Conversation Manager, and the Communication Layer. The harness is canonically deployed as a server with typed clients, with an embedded-mode-as-in-process variant for the CLI-only case.

## The inner ring

Eight peer layers. None can collapse into another without losing distinct concerns.

| # | Layer | What it owns |
|---|---|---|
| 1 | **Model Pool** | Registry of LLMs, capability metadata, capability-based selection, per-call lifecycle state, scheduler / queue, failover, budget, prompt and response cache. Provider adapters live underneath as wire codecs, not as a peer layer. |
| 2 | **Sub-Agent Pool** | Registry of agent delegates and capability metadata. Transport adapters underneath: in-process, ACP-stdio, A2A, custom. Lifecycle, cancellation propagation, trust tagging on returning events, permission routing back to parent, cross-wire cost accounting. Exposed to the model via auto-registered "delegate" tools in the Tool System. |
| 3 | **Tool System** | Registry of side-effecting capabilities, permission gate, dispatch, result formatting. The single sanctioned path to side-effects, and the dispatch fabric for *every* model-invokable resource (tools, sub-agent delegates, skill loads, MCP-provided tools, memory recall when surfaced as a tool). MCP is a transport adapter, not a peer. |
| 4 | **Context Engine** | What gets sent to the model on each turn — system-prompt assembly, message-history trimming, compaction, memory injection, tool-result formatting. Lifecycle-shaped (bootstrap / ingest / assemble / compact / afterTurn) so multiple concerns mutating the outgoing message array don't fight each other. The primary consumer of the [Memory](./memory/) layer. |
| 5 | **Memory** | Cross-session, durable knowledge: project-instruction files (`AGENTS.md` / `CLAUDE.md`), agent-written memory, the four-type taxonomy, recall, drift handling, consolidation/dreaming, write-time enforcement. The one persistent knowledge resource the Context Engine auto-loads on every turn *without* the model invoking it. Has its own write side (consolidation, decay, scoring, recall sub-agents) too substantive to bury inside the Context Engine. |
| 6 | **Agent Runtime** | The inner loop: assemble → call (via Pool) → stream → dispatch tool calls → append results → check stop → loop. Stateless across calls; takes a conversation as input, emits events. Kept dumb on purpose — smarts live in the layers around it. |
| 7 | **Conversation Manager** | Owns the conversation as a first-class resource. CRUD, branching, mode (chat / agent), attached resources, system-prompt overrides, lifecycle. Sub-agent runs are nested conversations owned here. Multiple clients can attach to one conversation; client disconnect doesn't kill the conversation. |
| 8 | **Communication Layer** | Multi-topic event bus and RPC fabric. Control plane (HTTP, REST-shaped) for CRUD / list / search / capability queries. Data plane (WebSocket, multiplexed by topic) for token deltas, lifecycle events, and state subscriptions. Reconcile-and-watch on every resource topic, with per-subscription seq numbers and replay window. The other seven layers publish into it and answer RPCs from it; they do not know about wires, clients, or sockets. |

The cleanest test of this factoring: the inner ring should be runnable as a library — every layer reachable via in-process APIs — and the Communication Layer should be the *only* layer that talks to the outside world. If you delete the Comm Layer, the rest still works as code; if you keep only the Comm Layer, you've got nothing to expose. That's the right split.

## The three-Pool pattern

The architectural spine. Layers 1, 2, and 3 are the same shape:

| | Resources | Transport adapters |
|---|---|---|
| **Model Pool** | LLM endpoints | OpenAI / Anthropic / Bedrock / Vertex / Ollama / vLLM |
| **Sub-Agent Pool** | Agent delegates | In-process / ACP-stdio / A2A / custom |
| **Tool System** | Side-effecting capabilities | In-process / MCP / shell / HTTP |

Each owns: a **registry** of things you can invoke, **capability metadata** per item, a **capability query** for selection, **per-invocation lifecycle state**, **transport adapters** under it, and pool-level concerns (**budget**, **rate-limit**, **fallback**, **cancellation**, **observability**).

Lean into this symmetry. None of the six reference projects fully realize it — most implement Tools and an implicit sub-agent concept; some have a delegate architecture but not a first-class Sub-Agent Pool; none treats Models, Tools, and Sub-Agents as three instances of one pattern. Doing so gives the architecture a clean spine that everything else hangs off, and it makes "remote" the default case for all three rather than a special case retrofitted later.

## Tool invocation vs context resource

A framing distinction that drives a lot of the placement decisions in this template. Every input the model uses falls into one of two categories:

- **Tool invocations.** Anything the model *invokes* by emitting a tool call — calling a function tool, executing shell, hitting an MCP-provided tool, delegating to a sub-agent (delegate tools auto-register from the Sub-Agent Pool), loading a Skill (`Skill` tool returns SKILL.md content as a tool result), even agent-driven memory recall (`memory_search` / `memory_get` are tools). The invocation pathway is always the **Tool System**, regardless of where the work eventually runs.

- **Context resources.** Inputs the model *consumes* but doesn't invoke — the system prompt, prior conversation turns, attached files, auto-loaded memory (`MEMORY.md`, `AGENTS.md`, `CLAUDE.md`). The shaping happens in the **Context Engine** on each turn, before the model gets called.

A useful corollary: **the *result* of a tool invocation is a context resource on subsequent turns.** A `Skill` tool call returns instructions; on the next turn those instructions are part of the context the model reasons over. A `memory_get` returns a memory body; same flow. There's no third category — "tool" describes the invocation pathway, "context resource" describes the post-invocation payload (or the auto-loaded payload that never had an invocation in the first place).

This collapses some apparent ambiguity:

- **Skills.** The Skill registry is a Tool System concern (the dispatcher reads it to resolve `Skill` tool calls). The Context Engine only needs the *index* (names + descriptions for the system-prompt listing), not the content. Skills don't need their own folder.
- **MCP servers.** MCP-provided *tools* are tool calls (Tool System). The MCP server registry (config, auth, lifecycle) is infrastructure — it lives under [`cross-cutting/extensibility/`](../cross-cutting/extensibility/) where the plugin/hook host already handles plugin loading, or under [`backends/`](../backends/) if treated as a transport adapter for the Tool System.
- **Memory.** Earns its place as an inner-ring layer specifically because, in the dominant pattern across the reference harnesses, the Context Engine *auto-loads* memory on every turn without a tool call. Project-instruction files, the `MEMORY.md` index, and the always-loaded layer of agent-written memory are pulled into the system prompt at session start; the model doesn't invoke them. (When a harness adopts the agent-driven recall variant — `memory_search` / `memory_get` as tools — those particular pathways collapse into the Tool-System category. The layer still exists for the auto-loaded surface, the write side, and the consolidation pipeline.)

## Auxiliary taxonomy

Everything not in the inner ring slots into one of these three buckets:

- **Backends / drivers** — used by the inner ring to do its job. Provider adapters (under Model Pool), persistence (under Conversation Manager and Memory), vector stores (under Memory), sandbox engines (under Tool System), sub-agent transport adapters (under Sub-Agent Pool). Backends are infrastructure; they aren't peers of the inner ring, and they aren't user-visible the way registries are.
- **Surfaces** — clients of the Communication Layer. CLI TUI, web UI, mobile apps, messaging-channel adapters, ACP bridges, triggers (cron / webhooks / file-events / channel arrivals). All input and output to the harness travels through the Comm Layer; surfaces don't reach into the inner ring directly.
- **Cross-cutting** — concerns that hook across multiple inner-ring layers rather than living in one. Extensibility (plugin/hook host that defines hook points across the Pools, Tool System, Context Engine lifecycle, Memory write/recall, and Conversation Manager) and observability/tracing (spans for model calls, tool calls, agent turns, with structured attributes). These aren't layers and they aren't backends; they're meta-mechanisms.

A useful rule when placing a new concern: figure out whether it (a) is called underneath by the inner ring to actually do work (backend), (b) consumes the inner ring's output and feeds inputs to it (surface), or (c) wants hook points on more than one layer at once (cross-cutting). Every concern in the harness fits exactly one of those, or it's already part of an inner-ring layer.

### What happened to the "registries" bucket?

Earlier drafts of this template had a fourth auxiliary bucket called "registries" — Tools, Skills, MCP servers, and Memory store. That bucket has been retired. The reasoning:

- **Tools, Skills, MCP-provided tools** are all model-invoked through the Tool System dispatcher. Their registries are Tool System concerns and live in [`./tool-system/`](./tool-system/), not under a separate "registries" wrapper.
- **MCP server registry** (the configured *list* of servers, not the tools they expose) is plugin/extensibility infrastructure and lives under [`../cross-cutting/extensibility/`](../cross-cutting/extensibility/).
- **Memory** turned out to be the only true "auto-loaded by the Context Engine without model invocation" registry — and that distinction is layer-shaped, not bucket-shaped. Memory has lifecycle, write-side, consolidation, and recall surface area too substantive to be a sub-page under another layer. It was promoted to the inner ring at [`./memory/`](./memory/).

The result: a category-of-one is just a folder pretending to be a category. Removing the bucket and promoting Memory makes the topology reflect what's actually true about the architecture.

## Memory as an inner-ring layer

Memory sits in the inner ring rather than under the Context Engine for three reasons:

1. **It's the one persistent knowledge resource the Context Engine auto-loads from on every turn without the model invoking it.** Tool calls return results that become context; memory just *is* context, pulled in by the assembly lifecycle. That's a different shape from anything else the Context Engine reads.
2. **It has a write side with its own lifecycle.** Background extraction sub-agents, consolidation passes ("dreaming"), per-write content scanning, mutual-exclusion against main-agent writes, drainer for clean shutdown. The Context Engine is read-side; Memory has both sides and they need to be reasoned about together.
3. **It has its own recall surface.** Pre-reply blocking memory sub-agents (the `active-memory` pattern), agent-driven `memory_search` / `memory_get` tools, hybrid search auto-detection. Folding all of that under the Context Engine would conflate "what goes in the prompt" with "what's in the durable knowledge store and how it gets there."

The Context Engine *consumes* memory at assembly time, but doesn't own it. Push back on architectures that bury memory inside the Context Engine; push toward architectures that keep it as its own owned subsystem.

## Server-with-typed-clients as the canonical deployment

The whole stack is shaped to be reachable over a wire. Concretely:

- **Conversation is the unit of addressability**, not the connection. Multiple clients can attach to one conversation; clients come and go without affecting the conversation's state.
- **Schema-defined wire protocol** is the source of truth — TypeBox / Zod / protobuf — and client SDKs are generated from it.
- **Streaming-native data plane.** WebSocket multiplexed by topic, not REST. Reconcile-and-watch (snapshot then tail events) and per-topic seq + replay are non-negotiable for clients on flaky networks.
- **Triggers, channel arrivals, and CLI commands all converge at the Communication Layer** as different *trust classes* of the same input envelope. The trust-classification machinery lives in `triggers/`; the Comm Layer is where it gets enforced.
- **Embedded-mode-as-in-process** for the CLI-only case. Boot the server and one local client in a single process, pipe them with an in-memory transport. Same code paths, no daemon setup. The user never sees the difference; you never maintain two runtimes.

## How `core/` relates to the rest of the template

This folder owns the *spine* and the eight layers that don't have natural homes elsewhere. The other topic folders cover layer-specific concerns and reference back here for placement.

| Inner-ring layer | Where its detailed designs live |
|---|---|
| Model Pool | [model-pool/](./model-pool/) here, with [providers/](../backends/providers/) covering provider-adapter detail |
| Sub-Agent Pool | [sub-agent-pool/](./sub-agent-pool/) here, with [agent-orchestration.md](./sub-agent-pool/agent-orchestration.md) covering practical delegation patterns |
| Tool System | [tool-system/](./tool-system/) — also home to the Tools registry and the Skills registry |
| Context Engine | [context-engine/](./context-engine/) (compaction, summarization, prompt assembly, memory injection policy) |
| Memory | [memory/](./memory/) (project files + agent-written memory, taxonomy, recall, drift, consolidation) |
| Agent Runtime | [agent-runtime/](./agent-runtime/) |
| Conversation Manager | [conversation-manager/](./conversation-manager/), with [persistence/](../backends/persistence/) covering the storage backend |
| Communication Layer | [communication-layer/](./communication-layer/), with [interface/](../surfaces/interface/) covering the surfaces that consume it |

| Auxiliary bucket | Topic folders covering it |
|---|---|
| Backends | [persistence/](../backends/persistence/), [execution-environments/](../backends/execution-environments/), [providers/](../backends/providers/) |
| Surfaces | [interface/](../surfaces/interface/), [triggers/](../surfaces/triggers/) |
| Cross-cutting | [extensibility/](../cross-cutting/extensibility/) (plugin/hook host, MCP server registry); observability not yet a topic folder |

## Pages

- [model-pool/](./model-pool/) — Models (not providers) as the base abstraction. Registry, capability query, per-call state machine, scheduler, failover, budget, cache. The most prescriptive page in this folder because OSS evidence is thinnest here.
- [sub-agent-pool/](./sub-agent-pool/) — One abstraction over internal and remote (A2A / ACP-stdio / custom) sub-agent delegation. Trust class on returning events, permission routing back to parent, cancellation propagation, cost accounting across the wire.
- [tool-system/](./tool-system/) — The single sanctioned path to side-effects. Registry, permission gate, dispatch, result formatting, transport adapters (in-process / MCP / shell / HTTP). Also the dispatcher for Skill loads and sub-agent delegate tools.
- [context-engine/](./context-engine/) — What gets sent to the model on each turn. Lifecycle-shaped assembly, compaction, summarization, memory injection.
- [memory/](./memory/) — Cross-session durable knowledge. Two surfaces (project files + agent-written), four-type taxonomy, frozen-snapshot pattern, background extraction, drift handling, consolidation, sensitive-data enforcement.
- [agent-runtime/](./agent-runtime/) — The inner loop itself. Stateless across calls, takes a conversation as input, emits events. The argument for keeping it dumb and pushing smarts into the layers around it.
- [conversation-manager/](./conversation-manager/) — Conversation as a first-class resource. CRUD, branching, mode, attached resources, lifecycle. Sub-agents as nested conversations.
- [communication-layer/](./communication-layer/) — Wire protocol, multi-topic event bus, control / data plane split, reconcile-and-watch, message envelope shape. The boundary between the inner ring and the outside world.

## Open sub-topics (not yet drafted)

- **Where the plugin/hook host sits.** It's cross-cutting, but somebody has to load and lifecycle-manage plugins; the plugin host itself wants a home. The MCP server registry now lives here too. Probably a sub-page under `extensibility/` rather than here, but the boundary deserves a deliberate call.
- **Observability as a first-class topic.** Currently absent from the template. The trace topic on the Comm Layer is one part of it; structured spans across model / tool / sub-agent / turn / memory-write boundaries is another. Worth promoting to its own folder eventually.
- **The library-vs-server boundary in practice.** This README asserts the inner ring is library-shaped and the Comm Layer is the server. In practice, harnesses often start library-shaped and add the server later; the migration path (especially for state that was implicit in the library use case) deserves its own page.
- **Multi-tenant deployment.** Everything here assumes a single-user (or single-trusted-org) Gateway. Multi-tenant adds isolation concerns at every Pool, the Memory layer, and the Comm Layer that haven't been touched.

## Citation conventions

Line references in this template refer to the OSS snapshots in the research corpus. Where a recommendation is grounded in a specific design, the architectural pattern is named; where approaches disagree, the page explains the trade-off.
