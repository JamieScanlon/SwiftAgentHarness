# Observability

## TL;DR

Observability is how signal leaves the harness — logs, structured events, traces, and cost/usage metrics — and where each is consumed (operator console, audit trail, billing, end-user `/trace` and `/usage`). It is **cross-cutting** because every inner-ring layer emits signal: the three Pools, the Agent Runtime, the Conversation Manager, and the Communication Layer all have lifecycle transitions worth recording.

The single decision that shapes everything is: **the [Communication Layer](../../core/communication-layer/) event bus is already most of your observability.** Turn lifecycle, tool dispatch, model state transitions, and sub-agent activity are structured event traffic on `conversation/{id}/events`, and persisting the bus *is* persisting the audit trail. Don't rebuild a parallel logging pipeline for what the bus already carries.

The prescriptive shape:

1. **Three signal planes, not one logger.** (a) The **event bus** is the in-conversation audit/replay surface — already persisted, already ordered, already replayable. (b) An **out-of-band structured logger** (JSONL) carries what the bus *can't*: crashes, internal warnings, Gateway/infra traffic, and anything that happens before a conversation exists. (c) **OTel-shaped trace/metric signal** is a third plane, cheap to disable and never on the critical path. Each plane has a distinct lifetime and consumer; collapsing them is the common mistake.
2. **One canonical usage shape, emitted as a first-class signal.** A `CanonicalUsage` record (`input / output / cacheRead / cacheWrite / reasoning` tokens + `requestCount`) rides the bus per model call and rolls up into the [persistence](../../backends/persistence/) catalog. Cost is `CanonicalUsage × a versioned pricing table`, computed once, never re-derived at call sites. This is what `/usage`, billing, and rate-limit feedback read.
3. **W3C `traceparent` for cross-Pool, cross-process propagation.** A turn spans Model Pool → Tool System → Sub-Agent Pool → (recursively) Model Pool. Mint a `traceId` per turn; propagate `traceId / spanId / parentSpanId` through the three-Pool symmetry, across the wire to remote sub-agents (ACP / A2A), and into MCP tool servers. A `callDepth` makes the recursion legible. Treat trace topics as OpenTelemetry-shaped under the hood; the wire is just transport.
4. **Redaction at the emit boundary, not the sink.** Prompts, tool inputs/outputs, and user content all flow through the signal stream. A scrubber masks secrets (API keys, bearer tokens, sensitive field names) *before* anything is written, and raw prompt/response content is **opt-in** (off by default). Telemetry hooks see sanitized metadata — timing, outcome, provider/model, a bounded request-id *hash* — never raw content unless a plugin is explicitly granted conversation access.
5. **Sampling and retention sized per signal class.** Token-delta events are extremely high-cardinality; sample or drop-after-window, never archive whole. Trace topics are cheap to disable. Replay windows are bounded per topic (small for token deltas, hours for registry changes); long-term archive is a separate decision from the bus replay window.
6. **Telemetry attaches via [extensibility](../extensibility/) hooks, not core forks.** OpenTelemetry exporters, trace loggers, and audit sinks register through the sanitized `model_call_started/ended`, `before/after_tool_call`, and `subagent_*` hooks. Core ships the instrumentation seam; exporters are plugins.
7. **Two audiences, two renderings.** Operator-facing telemetry is the full structured stream (JSONL / OTLP for collectors, a `/metrics` endpoint for Prometheus). User-facing telemetry is curated: `/trace`, `/usage`, `/cost`, `/verbose`, `/reasoning` expose friendly subsets. One emit path, two renderers — a console (TTY-aware, pretty) for local dev and structured JSON for production collectors.

The recommended design treats *the bus as the audit log*, *usage/cost as a first-class signal*, *traces as an OTel-shaped overlay*, and *redaction as an emit-boundary concern* — four orthogonal pieces. Reference implementations split on exactly how native the OTel layer is: the most elaborate ships a full OpenTelemetry traces/metrics/logs stack with OTLP + Prometheus + BigQuery exporters, a Prometheus `/metrics` endpoint, a cost tracker, and a scrubber; another leans on the event bus + W3C trace context + sanitized hooks + a JSONL file log and surfaces `/trace` `/usage` to end users; a third inherits a hosted trace backend for free from its runtime framework. All three are coherent under different constraints — see [Alternatives](#alternatives).

For the bus this page builds on, see [Communication Layer](../../core/communication-layer/). For where rollups land, see [Persistence](../../backends/persistence/). For the hooks telemetry attaches to, see [Extensibility](../extensibility/).

---

## How this fits the architecture

Observability has no home layer — it is the second [cross-cutting concern](../../core/README.md) (with [Extensibility](../extensibility/)) precisely because signal originates everywhere. The Model Pool emits per-call usage and failover classifications; the Tool System emits dispatch and approval events; the Sub-Agent Pool emits spawn/complete and cost-per-invocation across the wire; the Conversation Manager emits lifecycle transitions; the Communication Layer is the thing that *routes* all of it. A "logging layer" that tried to own this would have to reach into every other layer — which is exactly the tentacle problem the comm-layer page warns about.

The discipline that avoids it: **each layer emits; the Communication Layer routes; observability defines the signal contracts and the sinks.** Observability owns the *shape* of a log line, a span, a usage record; the *redaction rule*; the *sampling/retention policy*; and the *exporters*. It does not own the events themselves — those belong to the layers that emit them.

### The bus is already the audit trail

The comm-layer commits to a persisted, ordered, replayable event stream on `conversation/{id}/events`, with per-topic sequence numbers and a replay window. That stream already carries the turn lifecycle, tool dispatch, model state transitions, and sub-agent activity — i.e. most of what an operator means by "the logs." The page even states the intent directly: *"Trace topics should be cheap to disable (they're observability, not application data) and never on the critical path. Treat them as OpenTelemetry-shaped under the hood; the wire format here is just the transport."*

So the first architectural call is settled by the bus: **don't build a second pipeline for in-conversation signal.** What you *do* still need a separate channel for is everything the bus structurally can't carry — a crash before any conversation exists, a Gateway startup warning, a channel-reconnect storm, an internal invariant violation. That's the out-of-band logger's job, and only that.

### Three-Pool symmetry implies one span shape

The [three-Pool pattern](../../core/README.md) (Model / Sub-Agent / Tool) means a single turn recurses through the same structural shape: a Pool dispatches, work happens, a result returns. Observability should mirror that symmetry with **one span shape across all three Pools** — same `traceId`, parent/child `spanId` linkage, same attribute conventions (`pool`, `model`/`tool`/`agent` id, `durationMs`, `outcome`). When a turn fans out to a sub-agent, the sub-agent's spans are children of the spawning tool-call span, and its stream is a parallel topic (`subagent/{conv}/{path}/events`) — not multiplexed onto the parent. The trace tree and the topic tree are the same tree.

### What observability owns vs. what each layer owns

| Concern | Owner | Why |
|---|---|---|
| Event *content* (what a tool-dispatch event says) | the emitting layer | The layer knows its own semantics |
| Event *transport* (ordering, replay, fan-out) | Communication Layer | It owns the wire |
| Log-line / span / usage-record *shape* | **Observability (this page)** | Cross-layer contract |
| Redaction rule (what's masked, what's opt-in) | **Observability (this page)** | One boundary, applied everywhere |
| Sampling & retention policy | **Observability (this page)** | High-cardinality signal needs one policy |
| Token/cost rollup *storage* | Persistence (catalog) | It's a retention class |
| Cost *computation* (`usage × pricing`) | **Observability (this page)** | Pricing table + versioning |
| Exporters (OTLP, Prometheus, BigQuery, Sentry) | **Observability (this page)**, via [extensibility](../extensibility/) hooks | Pluggable sinks |
| End-user surfaces (`/trace`, `/usage`) | [Interface](../../surfaces/interface/) renders; observability supplies | Curated projection of the stream |

---

## The four signal kinds

Observability is not one stream; it is four signal classes with different shapes, lifetimes, and consumers. Treating them uniformly is the root error.

| Signal | Shape | Lifetime | Primary consumer | Carried by |
|---|---|---|---|---|
| **Structured events** | typed envelopes (`message` / `checkpoint` / `progress`) | persisted (transcript) + bounded replay window | live UI, history UI, audit, memory ingestion | the **event bus** |
| **Logs** | level + subsystem + message + scrubbed fields (JSONL) | rolling file, operator-policy TTL | operator console, crash forensics | **out-of-band logger** |
| **Traces** | spans with `traceId`/`spanId`/`parentSpanId`, attributes | sampled, short retention, off critical path | latency/causality debugging, distributed tracing backends | **OTel-shaped trace plane** |
| **Metrics & cost** | counters/histograms/gauges + `CanonicalUsage` records | aggregated, long retention | dashboards, billing, rate-limit feedback, `/usage` | **metrics endpoint + catalog rollups** |

The crucial non-overlaps: a **log** can exist with no conversation (a crash); an **event** is always conversation-scoped and persisted; a **trace** is ephemeral and samplable; a **metric** is an aggregate, not a record of one thing happening. A design that routes all four through "the logger" loses the bus's replay, the trace's sampling, and the metric's aggregation.

---

## Recommendation

### Three signal planes, kept distinct

Resolve the "event bus *or* separate logger?" question as **both, with a clean division of labor**, plus a third trace plane:

- **Plane 1 — the event bus** is the audit log for everything conversation-scoped. Turn lifecycle, tool dispatch, model-call start/end, sub-agent spawn/complete, compaction, approvals: these are already structured envelopes on `conversation/{id}/events`, already persisted by the transcript, already replayable by sequence number. Reading the audit trail = replaying the bus. Do not duplicate these into the file logger.
- **Plane 2 — the out-of-band structured logger** carries only what has no conversation to attach to: process crashes, uncaught exceptions, Gateway/channel infra (startup, reconnects, RPC errors), internal warnings and invariant violations. JSONL on disk (one rolling file, date-stamped, configurable path), tailable live (`logs --follow`) and surfaced in an operator Logs UI. This is small by construction — if you find yourself logging turn-by-turn detail here, it belongs on the bus.
- **Plane 3 — the OTel-shaped trace/metric overlay** is the distributed-tracing and aggregate-metrics layer. It is *derived* from the same lifecycle transitions the bus carries, but shaped as spans and counters for tracing/metrics backends. It must be cheap to disable and never on the critical path — a turn must not slow down or fail because a span exporter is unreachable.

The test for which plane a piece of signal belongs to: *does it have a conversation?* (→ bus), *is it infra/pre-conversation/crash?* (→ logger), *is it for latency/aggregate analysis?* (→ trace/metric overlay). Most "where does this log go" arguments dissolve once the three planes are named.

### One canonical usage shape; cost computed once

Make token usage a **first-class signal with a single canonical shape**, emitted per model call:

```ts
interface CanonicalUsage {
  inputTokens: number
  outputTokens: number
  cacheReadTokens: number
  cacheWriteTokens: number
  reasoningTokens: number
  requestCount: number      // >1 when a logical call retried/rotated
  rawUsage?: object         // provider-native payload, for audit
}
```

Every provider's wire codec normalizes into this shape (the [Providers](../../backends/providers/#wire-codec-stream-a-request-emit-normalized-events) `usage` event is exactly this). The Model Pool emits a `CanonicalUsage` per call onto the bus; the Conversation Manager rolls it up into the [persistence](../../backends/persistence/) catalog (`input_tokens`, `cache_read_tokens`, `reasoning_tokens`, … columns on `conversations`/`messages`).

**Cost is computed, not stored as truth.** Keep a versioned pricing table keyed by `provider/model` (USD per 1M tokens, per token class). Cost = `CanonicalUsage × pricing[model]`, computed at one place, with the `pricing_version` recorded so historical costs can be recomputed when prices change. Two distinct cost values are worth tracking: *estimated* (computed locally from usage) and *actual* (provider-reported, when a usage/billing endpoint exists). Surface both; don't conflate them.

This single shape is what makes `/usage`, billing rollups, budget enforcement (a Model Pool concern that *reads* this signal), and rate-limit feedback cheap. The anti-pattern is per-surface usage math: if `/usage`, the billing report, and the budget check each re-derive cost from raw provider payloads, they drift.

**Remote delegate cost must come home.** When a turn fans out to a sub-agent across the wire (ACP / A2A), the delegate's `CanonicalUsage` has to return across the transport adapter and attribute to the parent's rollup — otherwise sub-agent spend is invisible. Make cost-return part of the [sub-agent](../../core/sub-agent-pool/) completion envelope, not an afterthought.

### Trace propagation across the three Pools

Use **W3C Trace Context** (`traceparent`) as the propagation primitive — it's the interoperable standard and it crosses process boundaries for free:

- `traceId` — 32 hex chars, minted once per turn (or inherited from an inbound `traceparent` if a caller supplies one).
- `spanId` — 16 hex chars, one per unit of work (a model call, a tool dispatch, a sub-agent run).
- `parentSpanId` — links a span to its parent; this is what reconstructs the tree.
- `traceFlags` — the sampled bit; respect it end to end.
- `callDepth` — a harness-level convenience attribute that makes recursive fan-out (agent → sub-agent → sub-sub-agent) legible at a glance.

Propagation rules that matter:

1. **Across the three Pools, in-process:** thread the active trace context through the turn so a tool-call span is a child of the model-call span, and a sub-agent's model-call span is a child of the spawning tool-call span. One tree per turn.
2. **Across the wire to remote sub-agents:** inject `traceparent` into the ACP / A2A request so the delegate's spans join the parent trace. The delegate mints child spans under the inherited `traceId`.
3. **Into MCP tool servers:** pass `traceparent` on the MCP call so a tool server that emits its own spans joins the trace. Servers that don't participate simply don't — the harness's span still bounds the call.
4. **Onto the message surfaces:** carry `traceId / spanId / parentSpanId / callDepth` on message-hook contexts so plugins can correlate without reconstructing lineage.

Keep trace emission off the critical path: spans batch-export asynchronously; a dead exporter degrades to dropped spans, never a stalled turn.

### Redaction at the emit boundary

If the signal stream is the audit trail, then secrets and user content flow through it — so redaction must happen **where signal is emitted, before it reaches any sink**, not at each backend.

- **A scrubber masks secrets unconditionally.** Recursively walk any object before it's logged: replace sensitive field names (`password`, `token`, `authorization`, `api_key`, `access_token`, `refresh_token`, `private_key`, …) with `[REDACTED]`, and mask key/bearer patterns in free strings (keep a short suffix for debugging: `sk-ant-...abcd****`). Apply a depth limit so a pathological object can't hang the scrubber. This runs on every plane.
- **Raw prompt/response content is opt-in, off by default.** A `LOG_USER_PROMPTS`-style flag gates whether prompt and completion text reaches telemetry at all; default is `<REDACTED>`. The operator who needs prompt-level debugging turns it on deliberately and accepts the consequences.
- **Telemetry hooks get sanitized metadata, never raw content.** The `model_call_started/ended` hook surface deliberately exposes timing, outcome, provider/model, transport, and a *bounded request-id hash* — not prompts, history, responses, headers, or raw provider request ids. A plugin that needs conversation content must hold an explicit `allowConversationAccess` grant ([extensibility](../extensibility/) governs this). The default exporter cannot leak content it never receives.

The reason redaction lives at the boundary and not the sink: there are many sinks (file log, OTLP collector, BigQuery, Sentry, a `/trace` UI) and only one emit path. Redacting per-sink means N chances to forget; redacting at emit means once.

### Sampling and retention, per signal class

High-cardinality signal will overwhelm any backend at full fidelity, so size policy per class:

- **Token-delta events** are the highest-cardinality traffic and *cannot be coalesced* (each delta is unique payload). On the bus they get a *small replay window* (seconds) — enough to reconnect a dropped client mid-stream, not enough to archive. They are **not** exported to trace/metric backends individually; only their aggregate (tokens-per-turn) becomes a metric.
- **Trace spans** are sampled (respect the `traceFlags` sampled bit) and short-retention; the trace backend, not the harness, is the long-term store.
- **Lifecycle/audit events** persist in the transcript (the durable record) and keep a larger bus replay window; their long-term home is the transcript archive, governed by the conversation's retention policy — distinct from the bus replay window.
- **Metrics** aggregate by construction and retain long (they're cheap); cost rollups live in the catalog indefinitely.

The two retention knobs to keep separate: the **bus replay window** (how far back a reconnecting client can resync) and the **archive TTL** (how long the durable transcript/metrics live). They answer different questions; one per-conversation, one per operator policy.

### Telemetry attaches via hooks, not core edits

Exporters are plugins, not core features. An OpenTelemetry exporter, a hosted-trace-backend logger, a custom audit sink, an error-reporting integration — each registers through the [extensibility](../extensibility/) hook bus:

- `model_call_started` / `model_call_ended` — sanitized provider-call telemetry (the span source for model calls).
- `before_tool_call` / `after_tool_call` — tool dispatch spans and approval-decision events.
- `subagent_spawning` / `subagent_ended` — fan-out spans and delegate cost.
- `session_start` / `session_end`, `before_compaction` / `after_compaction` — session and context-lifecycle spans.

Core ships the *instrumentation seam* (the hooks fire with stable, sanitized payloads and correlation fields); plugins ship the *exporters*. The one open question worth flagging: a few backends want a lower-level instrumentation point than the public hook bus (e.g. wrapping every outbound HTTP call). Provide that as a separate, explicitly-internal seam rather than widening the public hooks — the public hooks stay sanitized and stable; the low-level seam is for first-party instrumentation that accepts coupling.

### Two audiences: operator stream vs. user surfaces

The same underlying signal serves two very different consumers, and they want different shapes:

- **Operator-facing** is the full structured stream. JSONL logs for collectors; OTLP export for a tracing backend; a Prometheus `/metrics` endpoint (HTTP request histograms, token counters, default Node/runtime metrics) for scraping; optional Sentry for errors. This audience wants completeness and machine-parseability.
- **User-facing** is curated and friendly. `/usage` (per-response or session token + cost footer), `/cost` (local cost summary), `/status` (session tokens + estimated cost + provider quota as a normalized "X% left"), `/trace` (the span tree for the last turn), `/verbose` and `/reasoning` (toggle visibility of internals). These are projections of the stream, rendered by the [Interface](../../surfaces/interface/); observability supplies the data, the surface decides the affordance.

One emit path feeds both; the split is at rendering, not at emission. And the **local-dev vs. production format split** is the same idea one level down: a single logger with two renderers — a TTY-aware pretty console (subsystem prefixes, level coloring, compact mode) for the developer at a terminal, and line-delimited JSON for the production collector. Don't fork the emit path to get two formats; pick the renderer from the environment.

---

## Alternatives

### OTel-native everything (the maximal stack)

One reference implementation's shape: a full OpenTelemetry stack wired at bootstrap — a tracer provider, meter provider, and logger provider with dynamically-imported OTLP / Prometheus / console exporters (lazy so startup doesn't pay for all six protocol variants), a Prometheus `/metrics` endpoint via a standard metrics library, a dedicated cost tracker with a pricing table and daily buckets, a recursive scrubber, an error-reporting integration, and session tracing (including a Perfetto/BigQuery export path for deep analysis). Prompt content is gated behind a `LOG_USER_PROMPTS`-style flag and redacted by default.

**When this works:** when you run a server with real operators, dashboards, and an SRE practice — the OTel ecosystem (collectors, Grafana, Honeycomb, etc.) is the payoff, and the maximal stack plugs straight in. It's the right target for a hosted, multi-tenant gateway.

**Why not as the baseline for everyone:** it's a lot of machinery for a single-user CLI. The dependency weight (six exporter variants, prom-client, OTel SDKs) and the operational surface (a `/metrics` endpoint to scrape, a collector to run) are pure overhead if nobody's watching a dashboard. The pieces worth taking unconditionally are the **scrubber at the emit boundary**, the **prompt-content opt-in flag**, and the **cost tracker with a versioned pricing table**; the full exporter matrix is opt-in.

### Tracing inherited from the runtime framework

A framework-coupled harness can get tracing "for free" when it runs on a graph-executor framework: every node execution is traced into the framework's hosted trace backend with no harness-side instrumentation.

**When this works:** when you've committed to the framework anyway. Zero-config tracing of the agent graph is genuinely valuable, and the framework's trace UI is purpose-built for LLM apps.

**Why not as the default:** the trace shape is the framework's, not yours — it traces *framework nodes*, which may or may not line up with the three-Pool spans you'd want. You inherit the framework's trace vendor, its sampling model, and its release cadence, and you can't easily emit the same spans to a generic OTel collector. It's tracing-as-adapter (bound to one backend) rather than tracing-as-native (W3C context you can export anywhere). Borrow the *ambition* (tracing should be automatic, not hand-rolled per call site); don't inherit the lock-in.

### Event-bus-only, no separate logger

The minimal coherent position: the bus *is* observability, full stop. Everything is an event on a topic; "logs" are just events on a `system/logs` topic; there is no out-of-band file logger.

**When this works:** for an embedded, single-process harness where there's no infra layer to speak of and nothing meaningful happens before a conversation exists. Conceptually clean — one stream, one mental model.

**Why not as the default:** the bus structurally can't carry what has no conversation. A crash during Gateway startup, an exception thrown before the first conversation is created, a channel-reconnect storm at the transport layer — these have no `conversation/{id}` to attach to, and forcing a synthetic one is worse than a plain log file. The moment the harness has a Gateway, channels, or schedulers, you need Plane 2. Keep the bus as the *audit* surface; keep a small logger for the infra edge.

### Pull-based metrics only (Prometheus endpoint, no event stream)

Expose a `/metrics` endpoint and let a scraper pull; don't push a structured event stream for observability at all.

**When this works:** as a *complement* — a `/metrics` endpoint is the right shape for aggregate operational metrics (request rates, latencies, token counters, runtime health) and pairs well with the bus. As the *only* observability, it's enough for "is the service healthy" dashboards.

**Why not as the whole story:** metrics are aggregates; they can't answer "what happened in *this* turn" or reconstruct a causal trace. You can't debug a specific bad run from counters. Use the pull endpoint for operational health and the bus + traces for per-turn forensics; they're complementary, not substitutes.

---

## Anti-patterns

- **A parallel logging pipeline for what the bus already carries.** Re-emitting turn lifecycle, tool dispatch, and model-call events into a file logger duplicates the audit trail, doubles the write cost, and lets the two views drift. The bus is the audit log for conversation-scoped signal; the file logger is only for the infra edge.

- **One logger for all four signal kinds.** Routing events, logs, traces, and metrics through a single "logger" loses the bus's replay (events), the trace's sampling (spans), and the metric's aggregation. Four signal classes, four shapes, four retention policies.

- **Per-surface cost math.** If `/usage`, the billing report, and the budget check each re-derive cost from raw provider payloads, they disagree. Normalize to one `CanonicalUsage` shape, compute cost once against a versioned pricing table, and have every consumer read the same number.

- **Treating estimated and actual cost as the same field.** Locally-computed cost (usage × pricing) and provider-reported cost are different numbers with different trust; collapsing them hides reconciliation errors. Track both, label both.

- **Sub-agent cost that never comes home.** A remote delegate that burns tokens without returning its `CanonicalUsage` across the transport makes fan-out spend invisible and budgets wrong. Cost-return is part of the completion envelope, not optional.

- **Redaction at the sink instead of the emit boundary.** With many sinks and one emit path, per-sink redaction is N chances to leak. Scrub once, at emission, before any backend sees the bytes.

- **Raw prompt/response content on by default.** If telemetry captures prompts and completions unless told not to, a leaked log archive is a content breach. Default to redacted; make full content an explicit, deliberate opt-in.

- **Telemetry on the critical path.** If a turn slows or fails because a span exporter is unreachable or a metrics push blocks, observability has become a liability. Trace/metric export is async, batched, and best-effort; a dead exporter drops signal, never stalls a turn.

- **Archiving token deltas at full fidelity.** Token-delta events are the highest-cardinality traffic and can't be coalesced; persisting every one to a trace backend is ruinous and pointless. Give them a small bus replay window; export only their aggregate as a metric.

- **Conflating the bus replay window with archive retention.** "How far back can a reconnecting client resync" and "how long do we keep the durable record" are different questions with different owners (per-conversation vs. operator policy). One knob for both either over-retains hot buffers or under-retains the audit trail.

- **Exporters baked into core.** Hard-wiring an OTLP/Sentry/BigQuery exporter into the runtime couples every observability-backend change to a core release and forces the dependency on harnesses that don't want it. Exporters register through extensibility hooks; core ships only the sanitized instrumentation seam.

- **Trace ids that die at the process boundary.** If `traceparent` isn't propagated to remote sub-agents and MCP servers, the trace tree truncates exactly where distributed debugging matters most. Inject W3C trace context across every wire hop.

- **One firehose for operators and end users.** Dumping the full structured stream at a user, or curating away the detail an operator needs, serves neither. One emit path; two renderings — full and machine-parseable for operators, curated `/usage`-style surfaces for users.

---
