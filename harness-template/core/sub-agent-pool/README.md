# Sub-Agent Pool — Recommended Architecture

## TL;DR

Treat **delegation to any agent — local or remote — as a single abstraction**. The Sub-Agent Pool is structurally identical to the [Model Pool](../model-pool/): a registry of agent entries with capability metadata, a capability-based query, a per-invocation lifecycle state machine, and **transport adapters** underneath that hide whether the agent runs in-process, over an ACP stdio bridge, over A2A to a remote endpoint, or via a custom transport. Returning events from remote agents are tagged with their **trust class** at the Pool boundary; permission requests bubble back through the parent agent's flow; cancellation propagates across the wire; cost is accounted per invocation across both in-process and remote work. The Pool exposes its delegates to the model via **auto-registered "delegate" tools** in the Tool System — from the model's perspective, calling `delegate_to_researcher` looks like any other tool call.

The reference projects ship pieces of this. This page describes the shape that combines in-process delegation, push-based completion delivery, an ACP runtime option, and a delegate-architecture tier model under one Pool interface.

---

## Why this belongs as its own layer (and as a peer of the Model Pool)

The choice is between treating sub-agents as a special case of tools (the single-binary CLI path) or as their own resource pool (this page's recommendation). Three failures of the "just a tool" approach push toward the Pool:

1. **Lifecycle complexity is hidden inside one tool implementation.** A sub-agent has its own context, its own tool calls, its own permission decisions, its own streaming output, may spawn its own sub-agents, may need to be cancelled when the parent is. None of that fits naturally into a tool's "call → result" lifecycle. Implementing all of it inside the tool body works but means none of the machinery is reusable for, say, an A2A delegate.
2. **Remote agents need a real registry and transport layer.** A2A defines agent discovery (agent cards), invocation, task lifecycle, artifacts. Modelling this as "register an HTTP-calling tool" forces you to re-implement the protocol for every endpoint and gives up the capability-query benefits.
3. **The three resource pools want to share machinery.** Capability query, lifecycle state, scheduler, transport adapters, observability — the same problems the Model Pool solves for LLMs are the problems the Sub-Agent Pool solves for delegates. Not having a Pool means re-solving them per call site.

The clean factoring keeps the lifecycle complexity in the Pool and exposes a tool-shaped interface to the model. Best of both worlds: the model interface stays simple (`delegate_to_X` is just a tool call), and the lifecycle complexity has a proper home.

A second framing worth holding onto: **"remote sub-agent" is the default case; "in-process sub-agent" is one transport adapter.** Once that lands, the architecture stops needing to special-case "what if it's local" anywhere — locality is a property of the chosen adapter, invisible to everything above it. This is the same trick the Model Pool plays with providers (Anthropic vs Bedrock vs Ollama-local are all just adapters).

---

## Recommendation

### One abstraction, three (or more) transport adapters

The Pool's surface to the rest of the harness is the same regardless of where the agent runs:

```ts
interface SubAgentPool {
  resolve(idOrQuery: string | AgentQuery): AgentEntry
  invoke(agent: AgentEntry, request: DelegateRequest, signal: AbortSignal):
    AsyncIterable<DelegateEvent>

  // Discovery
  list(): AgentEntry[]
  refresh(): Promise<void>          // re-probe remote agent cards, re-scan local agent definitions
}
```

Underneath, transport adapters implement the actual wire:

- **In-process adapter.** Spawn a nested conversation in the same Conversation Manager, run it, surface its events. Cheapest, fastest, full visibility. The default case for agents you author yourself. The nested run must execute on its **own** per-conversation execution context (its own orchestrator/model-client binding), not a shared session-level one — otherwise the child's run and the parent's contend for a single binding and thrash each other (a common failure when the child uses a different model, e.g. a small recall/extraction model). See [agent-runtime § Pooling a heavy execution context](../agent-runtime/#pooling-a-heavy-execution-context).
- **ACP-stdio adapter.** Spawn a child process that speaks ACP on its stdin/stdout, drive the protocol, translate ACP events into the Pool's `DelegateEvent` shape. The bridge for IDE-style agents and stdio-shaped MCP-server-style helpers.
- **A2A adapter.** Talk Google's Agent2Agent protocol to a remote endpoint: discover via agent card, send a task, stream events, fetch artifacts. The default for cross-organization or cross-vendor delegation.
- **Custom HTTP / WebSocket adapter.** For agent endpoints that don't speak A2A but expose a callable shape — internal services, vendor-specific APIs, legacy integrations.

All four emit the same `DelegateEvent` stream upward. Nothing above the adapter knows which transport ran.

### The agent registry entry

Mirrors the Model Pool's entry shape:

```ts
type AgentEntry = {
  id: string                        // canonical id, e.g. "researcher" or "remote/legal-review"
  displayName: string
  description: string               // for the model — what this agent does

  capabilities: {
    tools: string[]                 // tools this agent has access to (informational; for routing)
    model?: ModelQuery              // model class this agent prefers (used by in-process adapter)
    maxRecursionDepth: number       // how deep this agent can fan out further
    streaming: boolean              // does this agent emit progress events
    longRunning: boolean            // is this expected to take >minutes
  }

  routing: {
    useClasses: string[]            // ["research", "review", "code-execution"]
    cost?: { estimatedPerCall: number }   // for remote agents with known pricing
  }

  transport: TransportBinding       // how to actually reach this agent

  trust: {
    defaultLevel: "system" | "user-deferred" | "known-party" | "unknown-party"
    permissionPolicy: "auto" | "ask-parent" | "ask-user"
  }
}

type TransportBinding =
  | { kind: "in-process"; agentDefinitionId: string }
  | { kind: "acp-stdio"; command: string; args: string[]; env?: Record<string, string> }
  | { kind: "a2a"; agentCardUrl: string; authProfile?: string }
  | { kind: "custom"; adapterId: string; config: unknown }
```

A few notes:

- **Capabilities are informational** in the same way as model capabilities — they describe what the agent can do, not what it's being asked to do. The capability query uses them to rank candidates.
- **`trust.defaultLevel`** is the trust class assigned to events coming back from this agent unless the adapter sets it more specifically per event. In-process agents under the same user account default to `system`; A2A agents default to `known-party` or `unknown-party` depending on whether the remote is authenticated and recognized.
- **`permissionPolicy`** — `auto` means the parent grants whatever the sub-agent asks for (only safe for in-process under the same user); `ask-parent` means the parent agent's runtime decides (using its own permission state); `ask-user` means user approval is required for any sub-agent permission request. Default to `ask-parent` for in-process, `ask-user` for remote.

### Capability query as the routing surface

Same shape as the Model Pool's. The runtime asks for an agent by capability, not by id, when delegation is dynamic:

```ts
type AgentQuery = {
  needs: { useClass?: string; tools?: string[]; longRunning?: boolean }
  prefer?: { maxCost?: number; transport?: "in-process" | "remote" | "any" }
  excludeIds?: string[]
}
```

The most common pattern: the parent agent's tools include `delegate_to_researcher`, `delegate_to_code_reviewer`, etc. (see "auto-registered delegate tools" below) — those map to specific `AgentEntry`s by id. Capability query is for cases where the parent says "I need any agent that can do X" and the Pool picks. Worth supporting; not the dominant path.

### Per-invocation lifecycle state machine

Mirrors the Model Pool's state machine, with delegation-specific phases:

```
queued → dispatching → connecting → running → tool-calling → completing → done
                                         ├→ awaiting-approval (escalation back to parent)
                                         └→ delegating (sub-agent called its own sub-agent)
                                                            ├→ errored
                                                            └→ cancelled
```

The Pool publishes state changes onto `subagent/{conversationId}/{path}/state` and detail events onto `subagent/{conversationId}/{path}/events` (per the topic taxonomy in [communication-layer.md](../communication-layer/)). This is what makes parent-agent UIs render "researcher is searching, then summarizing, then waiting for permission to write a file" rather than just a spinner.

`awaiting-approval` is the state that doesn't exist in the Model Pool, and it's the one with the most subtlety — see "permission routing" below.

### Trust class on returning events

Every `DelegateEvent` coming out of an adapter carries a trust class. The Pool sets it from the agent's `trust.defaultLevel` and from per-event signals the adapter exposes:

- **In-process adapter.** Events default to the parent's trust class. The sub-agent runs under the same user; its tool results aren't more or less trustworthy than the parent's. (Exception: web-fetch results inside the sub-agent are still `unknown-party`; the adapter passes through whatever the inner Tool System tagged.)
- **ACP-stdio adapter.** Events default to `known-party` if the spawned binary is allowlisted; `unknown-party` otherwise. The user authorized the binary to run, but its outputs are external.
- **A2A adapter.** Events default to `known-party` if the remote agent's card is signed and the issuer is trusted; `unknown-party` if anonymous or unverified.
- **Custom adapter.** Adapter author specifies; default to `unknown-party` if unset.

The Context Engine and Tool System enforce based on the tag — same machinery as for triggers (see [../triggers/triggers.md](../../surfaces/triggers/triggers.md)). Anything coming back from a remote sub-agent is treated as content the sub-agent *said*, not content the user said. This is the difference between "Slack Bot can summarize for me" working and "Slack Bot can quote a malicious DM that prompt-injects me into wiring money" not working.

### Permission routing back to parent

The hard part. When a sub-agent (anywhere on the spectrum) wants to do something requiring permission — write a file, call a sensitive tool, send a message on a channel — that permission has to be authorized somewhere. Three patterns, picked per agent in `permissionPolicy`:

- **`auto`** — Pool grants. Only safe for in-process agents under the same user with the same tool whitelist as the parent. Default for trusted internal sub-agents that exist solely as the parent's helpers.
- **`ask-parent`** — Pool surfaces a permission request as an event on the parent conversation; the parent agent's runtime decides (using its own permission state, possibly batched approvals from earlier in the parent's turn). Default for in-process agents that have narrower trust than the parent.
- **`ask-user`** — Pool surfaces the request as a UI-bound event the user must approve. Required for remote sub-agents and for any sub-agent invoking a sensitive tool not pre-approved in the parent's session.

Mechanically: when an adapter surfaces a permission request, the Pool transitions the invocation to `awaiting-approval`, publishes a `permission-request` event, awaits a response, then continues. For remote adapters this is a multi-round-trip protocol (the remote sub-agent paused waiting for the parent to authorize); make sure your transport supports it. ACP and A2A both have primitives for this; custom transports often don't and need a convention layered on top.

This is the part of the architecture that A2A under-specifies. The protocol gives you task lifecycle but not "the remote agent wants to do X, may it?" Build the convention into the custom adapter and version it.

### Cancellation propagation

Parent cancels → in-flight sub-agents cancel → their sub-agents cancel. The Pool owns this:

- **In-process** — propagate via `AbortSignal` chained from parent to child invocations.
- **ACP-stdio** — send the ACP cancel message; if the child doesn't respond within a grace period, kill the process.
- **A2A** — task cancellation is a first-class A2A operation; call it.
- **Custom** — adapter author implements; document the contract.

The grace period for ACP stdio matters. Some sub-agent processes spawn their own subprocesses (bash sessions, browser instances) that hold resources. Just SIGKILL'ing the ACP child can leak the subprocess tree. Pool should propagate cancel-then-grace-then-kill, with a recovery hook for adapter-specific cleanup.

### Orphan recovery after gateway restart

A long-running sub-agent invocation that was in flight when the parent's gateway process died is **orphaned**: the parent's runtime is gone, the child's transport may or may not still be live, and no one is consuming the child's output. The Pool's restart contract handles this; the user should never have to clean up by hand.

**What "orphaned" means concretely.** Three transports, three failure shapes:

- **In-process** — the child conversation has `state.runStatus ∈ {running, awaiting-approval, cancelling}` and no live runtime invocation when the gateway starts. The child's `rawEvents` is intact (durable on disk); only the in-memory loop is gone.
- **ACP-stdio** — the child *process* may still be alive (orphaned by the parent's death) or may have died with the parent depending on process-group setup. Either way, no one is reading its stdout.
- **A2A / custom HTTP** — the remote task may still be running on the remote host. The local record of "I delegated to this remote agent" is in the parent's `rawEvents`, but the response correlation is lost unless the adapter persisted enough state to reconnect.

**The contract on gateway start:**

1. **Scan for orphans.** Walk the catalog for conversations where `state.runStatus` is non-terminal and `state.currentRunId` is set. For each, the [Conversation Manager's restart contract](../conversation-manager/runs.md#resumption-after-restart) appends a `run_orphaned` marker to `rawEvents`, sets `runStatus = "idle"`, clears `currentRunId`, and the conversation is reachable but not running. That handles **both** parent and child conversations uniformly — sub-agent runs are nested conversations, so the same scan picks them up.

2. **Surface orphans for the parent.** For each orphaned child whose parent conversation is still active, the Pool publishes a `subagent.orphaned` event onto the parent's `subagent/{conv}/{path}/events` topic. The parent's UI can render "researcher was running when the gateway restarted; choose: discard / re-spawn / inspect transcript." This is what prevents silent loss of in-flight delegate work.

3. **Handle abort markers.** If the child's `rawEvents` shows it was cleanly aborting (the parent had already called `cancelRun` on the child but the marker write didn't make it durable), the Pool treats this as `aborted` rather than `orphaned` and skips the parent prompt — the parent already knows. Equivalent: check whether the parent's `rawEvents` contains a `cancelRun` issued for this child.

4. **Optional: synthetic resume for opt-in agents.** For agents whose registry entry sets `recovery.allowAutoResume: true` (typically long-running async background tasks the user expects to complete), the Pool can send a synthetic resume message to the child instead of orphaning it. The recommended pattern: append a synthetic `InputMessage` to the child conversation with `customType: "auto_resume"`, clear the abort marker, and start a fresh runtime invocation. The child's runtime, being stateless and replaying from `rawEvents` (per [agent-runtime § Resumption](../agent-runtime/#resumption-stateless-replay-from-rawevents)), picks up from the same context with prompt-cache hits.

   **Default to off.** Auto-resume is correct for an async background bash run that hit a permission gate (the parent expects it to continue post-approval); it's wrong for a delegate that was making progress whose state was meaningfully in-memory. Make it opt-in per agent.

5. **Adapter-specific cleanup.** Each transport adapter exposes a `recover(orphanedInvocation): Promise<void>` hook called during the scan:
   - **In-process** — no-op (the in-memory state is already gone; `rawEvents` carries everything).
   - **ACP-stdio** — terminate any leaked child processes belonging to this invocation (process-group kill); flush stdio buffers.
   - **A2A** — best-effort poll the remote task; if it's still running, decide whether to cancel (default) or re-attach (only if the agent supports task-resume; A2A's `tasks/get` lets you check status, but re-attaching to a streaming task isn't universally supported). Document the contract per integration.
   - **Custom** — adapter author implements; default to log-and-orphan.

**The most common bug** in this area: failing to mark which active sub-agent runs are still "active" vs which were already mid-cancellation when the gateway died. Without that distinction, the orphan flow either re-prompts the user about a child that's already been cancelled (annoying) or auto-resumes a child that was already being torn down (correctness bug). The fix is making the cancellation marker (`run_cancelled`) durable *before* the runtime returns — so a process death between "fired the abort signal" and "appended the marker" leaves a recoverable state. See [agent-runtime § Cancellation hygiene](../agent-runtime/#cancellation-hygiene) for the ordering.



### Cost accounting across the wire

A remote A2A agent might be billed separately, or might pass through to the same provider account, or might be free. The Pool tracks cost per invocation regardless:

- **In-process** — cost flows from the inner Model Pool invocation; Sub-Agent Pool sums.
- **ACP-stdio** — adapter exposes cost from the child's `usage` events if available; otherwise the cost is "0 to me, but my tokens went somewhere."
- **A2A** — cost from the agent card's pricing or the protocol's cost-tracking primitive (where supported).
- **Custom** — adapter author decides; default to "unknown."

Per-invocation cost gets surfaced to the parent's budget tracker the same way model-call costs do. From the parent agent's perspective, "the researcher cost me $0.40" is the same shape of fact as "the model call cost me $0.10" — both go on the conversation's running tally.

The thing to watch: a remote agent can be cheap to *invoke* but spend the parent's resources downstream (e.g., it returns data that the parent then has to summarize with its own model calls). Cost accounting at the invocation boundary is one signal; track full conversation cost too.

### Auto-registered "delegate" tools in the Tool System

The Pool exposes its delegates to the model through ordinary tool calls. On agent registration, the Pool generates a tool definition for each delegate and registers it with the Tool System:

```ts
// For an AgentEntry with id="researcher"
{
  name: "delegate_to_researcher",
  description: "<from agent.description>",
  parameters: {
    task: { type: "string", description: "What to research" },
    context?: { ... },
    expectedFormat?: { ... }
  }
}
```

When the model calls this tool, the Tool System recognizes it as a delegate-class tool and routes the call to the Sub-Agent Pool's `invoke(...)` rather than executing in-process. From the model's perspective the call returns a result like any tool; under the hood the Pool runs the full delegate lifecycle, streams events to the parent's UI, and returns the final result (or summary) when complete.

Two design notes:

- **Synchronous vs push-based delivery.** The simple shape is synchronous: the tool call awaits until the delegate finishes. Works for fast delegations, fails for ones that take minutes. The push-based pattern is the right answer for long-running: the tool returns a run id immediately, then on completion the runtime *announces* a summary back to the parent chat with a stable idempotency key. Adopt push-based for `longRunning: true` agents; synchronous for short ones.
- **One delegate tool per agent, or one delegate tool with an `agent` parameter?** Both work. One-per-agent gives the model better discoverability and lets the description per agent be specific; one-tool-with-parameter is more compact and easier when the agent registry is large. Default to one-per-agent for ≤10 delegates; switch to one-tool-with-parameter when the registry is bigger.

### Streaming events into parent's topic graph

Per the topic taxonomy in [communication-layer.md](../communication-layer/), nested-agent activity is observable via `subagent/{parent-conversation}/{path}/events` and `.../state`. The Pool's job: every adapter must translate its native event stream into the `DelegateEvent` shape, which the Pool then publishes onto the right topic.

Path naming for nested agents: `parent.task1.subtask1` style — the path identifies the location in the fan-out tree. This makes UIs that render "tree of running agents" tractable; without it, the parent can't tell which delegate emitted which event when there are concurrent delegates.

### Multi-recursion safety

Sub-agents can spawn sub-agents. Without bounds, a buggy or adversarial agent can fan out indefinitely. The Pool enforces:

- **Per-agent `maxRecursionDepth`** in the registry entry. Default to a small number (3 or 4); some agents legitimately need more (planning agents that decompose deeply); some shouldn't recurse at all (`maxRecursionDepth: 0`).
- **Per-conversation total-fanout cap.** Bounds the total active sub-agents in one conversation tree. Hit cap → reject new spawns, surface back to the requesting agent.
- **Total cost budget at the conversation level.** Already enforced by the Model Pool's budget; sub-agent invocations contribute to the same pot. Hit budget → reject.

The depth-limiting pattern (enforced at spawn time) is described in detail in Concrete operational defaults (depth 1 default with opt-in to 2 for orchestrator patterns, role parameter on the spawn call, global kill switch, lane-aware FIFO with per-session and global concurrency caps) live in [agent-orchestration.md → "Nesting depth"](./agent-orchestration.md#nesting-depth) and [agent-orchestration.md → "Concurrency: lane-aware FIFO"](./agent-orchestration.md#concurrency-lane-aware-fifo-with-per-session-and-global-lanes).

### Capability tiers and two-layer enforcement

Where the Pool sits in a delegate-architecture deployment — when an agent acts "on behalf of" a human in an organization — the registry entry's `capabilities` field carries an explicit **tier** that the parent must respect, *and* the Pool enforces a **two-layer block** independent of any prompt-level guidance.

- **Tier 1 (Read + Draft).** Read inbox / calendar / docs, draft messages for human review. No outbound writes. The most permissive default.
- **Tier 2 (Send on Behalf).** Agent has its own identity (email, calendar) and sends "Delegate Name on behalf of Principal Name." Identity-provider-backed.
- **Tier 3 (Proactive with Cron).** Tier 2 plus autonomous standing orders driven by triggers. Highest authority; requires explicit opt-in in the registry entry.

The tier is metadata on `AgentEntry`; the Pool surfaces it in the auto-registered tool's description so the model knows what kind of delegate it's invoking. But that's not the load-bearing enforcement — the Pool's permission gate is.

**Two-layer hard block.** Don't trust either layer alone:

- **Layer 1 (prompt-level guidance):** the agent's `SOUL.md` / `AGENTS.md` defines what the agent must never do. Prompt-injection-resistant *only to the extent the model honors its own system prompt*, which is to say: not very.
- **Layer 2 (Pool-level allow/deny):** the registry entry's `capabilities.tools.allow|deny` is enforced at dispatch time. Even if a sub-agent is talked into bypassing its rules, the Pool blocks the disallowed tool call before the Tool System runs it.

For high-security deployments, sandbox isolation is a third layer: each agent runs in its own sandbox, unable to reach beyond its allowed tools regardless of whatever the model requests. (Sandbox lifecycle belongs to the Tool System; the Pool's job is to mark the agent entry as requiring it.)

 Practical config and tier-by-tier deployment guidance live in [agent-orchestration.md → "Delegate architecture: tier model with two-layer hard blocks"](./agent-orchestration.md#delegate-architecture-tier-model-with-two-layer-hard-blocks).

### Multi-agent hosting and routing

A subtle architectural distinction worth being explicit about: **sub-agent spawning** (one parent invokes a child via `invoke(...)`) and **multi-agent hosting** (the harness runs many independent agent personas in one process) are separate concerns. The Pool participates in both, but they're different mechanisms.

- **Sub-agent spawning** is what the rest of this page covers — `parent.invoke(child)` through the Pool, with parent/child relationship, inheritance, and result handoff.
- **Multi-agent hosting** is the harness running N peer agents at once, each with its own workspace, auth profiles, session store, and (often) its own incoming channel routes. The Pool's `list()` includes all of them; transport adapters target a specific agent by id; channel-binding rules direct inbound triggers to the right agent.

The Pool's role in multi-agent hosting:

- **Agent identity in the registry.** Each hosted agent appears as a top-level `AgentEntry` with its own workspace path, auth profile, default model, tool whitelist. Workspace files (`AGENTS.md`, `SOUL.md`, etc.) are per-agent and the Pool tracks them per-id.
- **Cross-agent invocation gated.** By default, agent A cannot `invoke(agent B)` — multi-agent hosting is for routing, not for free intermixing. The Pool exposes this as `capabilities.allowDelegateTo: string[]` on each entry (specific ids, or `["*"]` for any). A "router" agent that dispatches to specialists is the canonical case for opening this up.
- **Auth profiles never auto-shared.** Each hosted agent's credentials are scoped to that agent. A delegate call doesn't inherit the requester's auth.
- **DM scope policies** for channel surfaces — how DMs split into sessions, scoped per agent — are part of the agent's registry entry, not global.

The default config — single agent named `main` — should require zero ceremony. Multi-agent should require an explicit setup step that creates the per-agent workspace and seeds files.

 Practical setup, channel-binding configuration, DM-scope policies, and the relationship to the spawn tool live in [agent-orchestration.md → "Multi-agent routing as a first-class concern"](./agent-orchestration.md#multi-agent-routing-as-a-first-class-concern).

### Pluggable Pool: the swappable executor

For harnesses with significant surface area, the Pool itself can be a pluggable extension point — a third-party agent runtime can own the model loop, native thread state, and native tool execution while the harness retains the Pool's outer machinery (registry, capability query, transport adapters, lifecycle state, observability).

This is the most architecturally heavy form of pluggability available in this layer:

- **The plugin owns the inner loop** — when invoked through the Pool, it runs its own model dispatch, tool execution, and compaction. The Pool sees a black box.
- **The harness retains the outer machinery** — registry, capability metadata, lifecycle state, channel delivery, tool dispatch (when the plugin asks the harness to execute a tool), provider/model selection (the plugin can request a model; the Pool picks the binding), sandbox policy.
- **The runtime split is documented surface-by-surface** — model-loop owner, canonical thread state, dynamic tools, native shell/file tools, context-engine integration, compaction owner, channel delivery. Each surface is either native, plugin-native, or bridged.
- **Selection rules**: the recorded runtime for an existing session always wins (never hot-switch). New sessions pick by env var override, then per-agent or default config. Explicit plugin runtimes fail closed by default — `runtime: "codex"` means Codex-or-error unless `fallback: "native"` is set in the same scope.

This is heavy machinery; only invest if you have a real need (cross-product runtime federation, embedded vendor agents, explicitly multi-vendor deployments). For a coding-agent CLI, native is fine.

The `AgentHarness` plugin slot registers an executor that owns model loop / native thread state / native compaction / native tool execution while the host harness still owns channels, transcripts, sandbox policy, and tool dispatch. See [agent-orchestration.md → "AgentHarness"](./agent-orchestration.md#agentharness-swappable-executor-as-a-plugin-slot).

Practical detail (the runtime-ownership matrix, selection-rule edge cases, fallback semantics) lives in [agent-orchestration.md → "Agent harness as a swappable executor"](./agent-orchestration.md#agent-harness-as-a-swappable-executor-advanced).

---

## Alternatives

### Sub-agents as just tools (single-binary CLI alternative)

The simplest factoring: treat delegation as a tool implementation. The tool body owns the spawning, the state, the streaming, and the result handoff.

**When this works:** when sub-agents are always in-process, always spawned by your own runtime, always short-lived, and always under the same trust class as the parent. A single-binary coding agent CLI is sized for this and can get clean code out of it because it doesn't need remote agents, doesn't need long-running push-based delivery, and doesn't need cross-trust permission flows.

**Why not as default:** it doesn't generalize to remote, it conflates lifecycle with invocation, and it makes it hard to add multi-recursion safety, cost accounting, or capability-based routing later. The reusable parts of sub-agent machinery are stuck inside one tool implementation. Defensible for a single-binary CLI; not for a server-shaped harness with potential A2A reach.

### Remote agents via custom HTTP, no abstraction

Each remote agent gets its own HTTP-calling tool, with the wire format hardcoded per integration.

**When this works:** when you have one or two specific remote agents and don't expect more. Quick to ship.

**Why not as default:** every new remote agent is a new tool implementation; capability discovery doesn't exist; permission flow is reinvented per integration; the remote agents can't be substituted by capability ("any agent that can do X"). Becomes unmanageable past three integrations. If you have N>1 remote agents, you want a transport adapter abstraction.

### Treat ACP as the only protocol

Standardize on ACP for both internal and remote; no in-process adapter.

**When this works:** if your harness already speaks ACP fluently and the overhead of stdio for in-process is acceptable. There's a real elegance to "everything is just an ACP child."

**Why not as default:** in-process delegation through stdio adds serialization, IPC latency, and process lifecycle management you don't need when the agent is yours. Also: ACP doesn't cover cross-organizational delegation (no agent-card-style discovery, no cross-vendor task semantics). A2A is a better fit for that. The single-protocol approach foregoes both performance (for in-process) and standardization (for cross-organizational). Use ACP as one transport, not the only one.

### One coordinator agent that owns all delegation

Centralize all sub-agent invocations through a single coordinator agent that the parent calls into.

**When this works:** when delegation logic is complex enough to warrant its own agent — sequencing, dependency resolution, retry policy, result composition — and you want it as model-driven logic rather than runtime code. Some workflow-heavy systems are shaped this way.

**Why not as default:** adds latency (every delegation is two model calls — the parent calling the coordinator, the coordinator calling the actual delegate). Concentrates failure modes in the coordinator. Most delegation isn't that complex; the runtime can dispatch directly. Reach for this when delegation logic genuinely needs model intelligence; otherwise let the parent agent decide directly.

---

## Anti-patterns

- **In-process and remote with different APIs.** A `Subagent` interface for local and an `RemoteAgent` interface for remote, each with their own state machine and call shape. Forces every consumer to dispatch on locality. Fold them under one Pool with transport adapters.
- **Permission flow that doesn't bubble back through the parent.** A remote sub-agent prompts the user directly for approval (e.g., the A2A endpoint pops up its own UI). The parent agent doesn't know what it consented to; the user can't tell which agent in the chain is asking. All permission requests go through the parent's flow, surfaced to the user via the parent's Comm Layer subscription.
- **No trust class on remote events.** The Pool blindly forwards remote sub-agent output as if it were `system` content. Now the model treats arbitrary agent output as authoritative, and prompt-injection in the remote agent compromises the parent. Tag every event from a remote adapter with at least `known-party`.
- **Fire-and-forget invocations with no completion path.** The Pool starts a sub-agent and never publishes a completion event; the parent has to poll. The right pattern is push-based delivery with idempotent retries; models should not poll `subagents list` waiting for completion.
- **Cancellation that doesn't propagate.** Parent's turn is cancelled; sub-agents keep running; they call tools; results arrive after the parent moved on. Pool must propagate cancel down the tree, and adapters must respect it (with grace + force-kill for stdio).
- **Cost accounting that stops at the invocation boundary.** "The remote agent cost $0.10" — fine — but the parent then has to do $2 of summarization on the result. Track full per-conversation cost, not just per-invocation.
- **Letting one delegate tool per agent explode the tool registry.** With 50 delegates, 50 tools is too many for the model to handle well. Switch to one-tool-with-`agent`-parameter shape, or partition delegates by sub-pool that the parent has to opt into.
- **No depth or fanout limits.** A buggy planner agent decomposes "do my taxes" into 100 sub-tasks each of which spawns 10 sub-sub-agents. Bound depth and fanout at the Pool layer; surface explainable rejections back to the requesting agent.
- **Fork-spawned children keeping the parent's capability set.** A `context: "fork"` delegate inherits the parent's transcript — that's the point of forking — but if it also inherits the parent's mode, it runs with the parent's full tool/skill allow-list. Forking copies *context*; capability (tools, skills, mode, trust) must be assigned fresh from the child's own role. Funnel every spawn shape (fork and isolated) through one capability-assignment step so no path can reintroduce the leak. See [modes.md § Branching behavior](../conversation-manager/modes.md#branching-behavior).
- **Scoping a child's capability to the parent's trust instead of the content's.** A delegate that ingests untrusted content — a memory-extractor reading raw transcript, a trigger worker reading an inbound payload — is a prompt-injection surface: text it processes can try to drive its tools. Scope its capability to the trust of the *content it handles* (least privilege, often near-empty), not to what the parent was allowed to do. "Parent could, so child can" is exactly how injected transcript text reaches privileged tools.

---
