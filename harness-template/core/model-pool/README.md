# Model Pool — Recommended Architecture

## TL;DR

Treat **models, not providers, as the base abstraction**. The Model Pool is a registry of model entries with capability metadata, a capability-based query API for selection, a per-call lifecycle state machine, a scheduler that bounds concurrency and enforces budget, automatic failover across capability-equivalent models, and a prompt + response cache. Provider adapters live *inside* the Pool as wire codecs — they translate "this model wants this request" into "this provider's wire format." Nothing else in the harness should know about providers; everything else asks the Pool for a model by id or by capability.

This is the most prescriptive page in `core-architecture/`. No OSS harness fully implements the Pool pattern — the closest approach has a real model registry and capability metadata, but no scheduler, queue, or lifecycle state. Most of the recommendations here are forward-looking: the *shape* the OSS landscape is converging toward, not what any one project ships today.

---

## Why this belongs in the harness

A harness whose only model interaction is "call the SDK, await the response" is sized for one thing happening at a time. The minute the harness has any of the following — and any non-toy harness has at least three — that shape breaks:

- A planner agent that spawns sub-agents (multiple concurrent model calls per session)
- Background jobs (memory consolidation, periodic compaction, summarization)
- Cost-conscious routing (cheap model for classification, expensive for code review)
- Multi-provider deployment for resilience (failover across Anthropic / Bedrock / Vertex)
- Per-user or per-session budget limits
- Observability that tells the user "the agent is currently waiting on the model" vs "currently executing a tool"

Without a Pool, each of these gets solved ad-hoc in the layer that needs it. Concurrency limits get enforced in the scheduler that nobody owns; failover gets re-implemented per call site; budget tracking lives in whatever middleware happened to be in scope; "what is the model doing" is unanswerable because no layer tracks it. The Pool exists so all of these concerns have one home.

A second reason worth naming: **the model is the most expensive resource in the system.** It's the primary cost driver, the primary latency driver, the primary failure mode, and the primary capacity constraint. Resources of that weight deserve a dedicated management layer; they don't deserve to be smeared across whichever code happened to need them.

---

## Recommendation

### Models, not providers, as the base abstraction

The user-facing concept is *which model*, not *which provider*. "Use Sonnet 4.6 for planning, Haiku 4.5 for cheap classification, GPT-5.5 for code review" — those are model decisions. Providers come into play when the Pool needs to know *how to talk* to a chosen model: which API shape, which auth credential, which streaming format. That's a wire concern, not a routing concern.

This inverts the conventional layout. Most harnesses have a `Provider` class with model strings as parameters; the Pool flips it: there's a `Model` registry entry, and `provider` is a field on it (or, in cases like Sonnet-via-Anthropic vs Sonnet-via-Bedrock, a small list of provider adapters keyed by reachability). The recommended shape: a generated `MODELS` map keyed by `provider/modelId` with capability and cost metadata per entry, and the runtime selects by model. The selector knows nothing about provider semantics; it knows about models.

The right test for this layering: can a user say "use Sonnet 4.6, I don't care which provider serves it" and the Pool make the right call? If yes, the abstraction is right. If the user has to pick `anthropic/claude-sonnet-4.6` vs `bedrock/anthropic.claude-sonnet-4.6` themselves, the layering is provider-first.

### The model registry entry

Every model in the registry carries:

```ts
type ModelEntry = {
  id: string                        // canonical id, e.g. "sonnet-4.6"
  family: string                    // "claude-sonnet" | "gpt-5" | "deepseek-v4"
  displayName: string

  capabilities: {
    contextWindow: number           // tokens
    maxOutput: number
    tools: boolean                  // tool/function-calling support
    vision: boolean                 // image input
    audio: boolean
    reasoning: "none" | "optional" | "required"  // "optional" = extended thinking available; "required" = always-on reasoning model
    promptCache: "none" | "ephemeral" | "persistent"
    streaming: boolean
    structuredOutput: boolean       // JSON mode / schema-constrained
    parallelToolCalls: boolean
    toolChoice: "none" | "auto" | "required" | "named"
                                    // forced-tool-choice support ladder, see note below
  }

  cost: {
    input: number                   // $ per 1M tokens
    output: number
    cacheRead: number
    cacheWrite: number
  }

  performance: {
    p50LatencyMs?: number           // observed, updated by scheduler
    tokensPerSecond?: number
  }

  routing: {
    useClasses: string[]            // ["planning", "code-review", "classification"]
    rateLimit?: { requests: number; tokens: number; windowMs: number }
  }

  providers: ProviderBinding[]      // one or more adapters that can serve this model
}

type ProviderBinding = {
  providerId: string                // "anthropic" | "bedrock" | "vertex" | "ollama"
  endpointModelId: string           // provider-specific name, e.g. "anthropic.claude-sonnet-4-6"
  authProfile: string               // which credential set
  priority: number                  // failover order
}
```

A few notes on the shape:

- **Capabilities are facts about the model, not requests against it.** `tools: true` means "this model can be asked to use tools," not "tools are enabled for this call." Per-call requests get validated against capabilities at dispatch time. Similarly, `reasoning: "optional"` means extended thinking is *available* for the model — it does not mean thinking is enabled on a given call. The per-call thinking configuration is resolved separately (see "Thinking configuration" below).
- **`toolChoice` is a support ladder, not a request.** It records how far a binding can be *forced* to call a tool: `"none"` = the endpoint ignores tool-choice directives entirely; `"auto"` = it accepts tools but only the model decides; `"required"` = it honors "you must call some tool"; `"named"` = it can also be pinned to a specific tool. Each rung implies the ones below it. This is the missing fact that lets the harness stop assuming every `tools: true` binding also honors `required` — a bad assumption for many Ollama / LM Studio / llama.cpp endpoints serving open weights. The runtime still emits the *abstract* `toolChoice` value (`"required"` / `{tool: name}`); at dispatch the Pool validates it against this capability and the provider adapter emits the wire field (`tool_choice`) **only when the binding reaches that rung**. When it doesn't, the adapter omits the field — a no-op at the wire — and forcing falls to the runtime's behavioral path (see [agent-runtime § Forced tool choice](../agent-runtime/#forced-tool-choice-stays-provider-agnostic)). Crucially, the capability changes only how the request is *encoded*; it is never the thing that *guarantees* a tool call. Because support varies by endpoint for identical weights (Sonnet via Anthropic honors `required`; the same model via a thin OpenAI-compat proxy may not), the baseline lives here on the model entry but a `ProviderBinding` may override it downward.
- **`useClasses`** is a soft routing hint — what kinds of work this model is good for. Lets the capability query pick a model by job type rather than by id.
- **Multiple `providers`** is how you express "Sonnet 4.6 is available via Anthropic, Bedrock, and Vertex." The Pool's failover policy picks among them on error.
- **`performance` is observed, not declared.** The scheduler updates these from real call data; they're not for the user to set. Used by the routing layer for latency-aware selection.

### Capability query as the routing surface

Other layers ask the Pool for a model by capability, not by id. The query is the thing they call:

```ts
type ModelQuery = {
  needs: Partial<ModelEntry["capabilities"]>   // hard requirements
  prefer?: {
    useClass?: string
    minContextWindow?: number
    maxCostPer1MTokens?: number
    family?: string
  }
  excludeFamilies?: string[]
}

interface ModelPool {
  resolve(idOrQuery: string | ModelQuery): ModelEntry
  resolveAll(query: ModelQuery): ModelEntry[]   // ranked candidates
}
```

Examples:

- "Give me a model with tool support, ≥200k context, that costs <$5/1M output tokens, ranked." Returns a list; the runtime takes the first.
- "Give me Sonnet 4.6 specifically." Returns the named model if available, throws if not.
- "Give me anything good for classification." Returns ranked models with `useClasses` containing `"classification"`.

This is what makes the Sub-Agent Pool's "delegate to the cheapest capable model" possible; it's what makes failover transparent; it's what lets a user override "use a cheaper model for this task" from configuration without touching code.

The thing none of the six reference harnesses do: when the runtime calls into the Model Pool, it should hold a `ModelEntry` it got from a query — not a string. This keeps the routing decision centralized. If you're seeing model strings hardcoded in runtime code, capability query isn't the routing surface yet.

### Per-call lifecycle and the state machine

Every call through the Pool moves through a state machine:

```
queued → dispatching → connecting → streaming → tool-calling → completing → done
                                                            └→ errored
                                                            └→ cancelled
```

The Pool publishes state changes onto `model/{id}/state` (see [communication-layer.md](../communication-layer/)). This is what the "what's the agent doing right now?" UI surfaces consume. Distinctions worth keeping:

- `queued` — awaiting a slot under the scheduler / rate-limit budget.
- `dispatching` — chosen, passed to the provider adapter, request being assembled.
- `connecting` — request sent, awaiting first byte.
- `streaming` — tokens / events arriving. This is the "generating" UI state.
- `tool-calling` — a tool call has been emitted; the runtime is dispatching it. (Pool cares because the model is no longer producing tokens — useful for budget pause and context-budget tracking.)
- `completing` — final tokens arriving, stop reason determined.
- `done` / `errored` / `cancelled` — terminal.

The "thinking" UI signal you're looking for is *derived*: a model in `connecting` for >200ms, or in `streaming` while emitting reasoning blocks rather than visible content. The Pool computes this signal so every UI surface gets the same answer rather than each rolling its own.

### Scheduler and concurrency control

The Pool owns concurrency. Concretely:

- **Per-model in-flight cap.** Configurable, defaults to provider rate-limit / safe headroom. Excess requests queue at `queued` state.
- **Per-account / per-credential cap.** Multiple models served by the same provider account share a rate-limit window. Track at the credential level, not just the model.
- **Token-bucket rate limit.** Both request-rate and token-rate (input + output projected). Provider rate-limits are usually expressed both ways; honor both.
- **Priority queue.** Foreground (user-blocking) requests jump ahead of background (consolidation, summarization). Two priority classes is enough; more is over-engineering.
- **Backpressure visibility.** Queue depth published onto `pool/health`. Surfaces can render "model X is queued, ETA ~Ns."
- **Per-conversation fairness.** A single conversation that fans out 20 sub-agents shouldn't starve other conversations. Round-robin across conversations within a priority class.

Most of the OSS harnesses just call the SDK in-line and let the provider's rate-limit error be the backpressure signal. That works for one user one conversation; it falls apart with concurrent sub-agents.

### Failover policy

When a `ProviderBinding` errors transiently (5xx, 429, timeout, disconnect):

1. **Retry on the same binding** with exponential backoff, capped (default: 2 retries, jittered, max 5s).
2. **Failover to next binding** for the same model (Sonnet via Bedrock if Anthropic 5xxs).
3. **Substitute by capability** if all bindings fail and the call is non-essential — e.g., switch from Opus to Sonnet for a background classification. Requires explicit caller opt-in (`allowSubstitution: true`); default off.
4. **Surface error** if substitution is off or no equivalent exists. The Pool emits a typed error; the runtime decides whether to fail the turn or surface a recoverable "model unavailable" state to the user.

The substitution rule is the part to be careful with: silent capability downgrades are dangerous (a planning step done with a worse model produces worse plans, and the user doesn't know). Default-off is correct; opt-in for jobs where "any capable model" is genuinely fine.

### Budget enforcement as a Pool concern

The Pool is the chokepoint where budget gets enforced because it's the only layer with cost visibility. Three scopes:

- **Per-call budget.** Caller can pass `maxCost: $X`; if projected cost (input tokens + estimated output) exceeds, reject before dispatch.
- **Per-conversation budget.** Per the conversation's metadata; cumulative across all calls in that conversation. Hit threshold → reject new calls, surface state.
- **Global / per-account budget.** Daily or monthly. Hit threshold → emergency reject.

Track at the `dispatching` boundary (so cancelled calls don't count) and finalize at `done` (real cost, not projected). Publish remaining budget onto `pool/health` and per-conversation budget onto `conversation/{id}/state` so surfaces can render warnings.

### Cache strategy

Two caches, both Pool-owned because their keys depend on model + provider:

- **Prompt cache.** Anthropic's ephemeral cache, OpenAI's prompt caching, Bedrock's equivalent. The Pool decides cache breakpoints based on the model's `promptCache` capability and the structure of the request. Important: cache keys are per-provider (Bedrock and Anthropic don't share caches), so the cache tier interacts with failover — failing over invalidates cache savings. Track the cost trade-off per call.
- **Response cache.** For idempotent calls only. Most agent calls aren't idempotent (the message history is unique per call) so this is narrower than it sounds; it's mostly useful for capability classifications, embeddings, and stable summarization tasks. Off by default; opt-in per call.

### Thinking configuration

Thinking (extended reasoning) is a per-call option on models where `capabilities.reasoning === "optional"`. It is *not* a capability fact — it's a request against a capable model. The Pool resolves it from a three-layer priority chain, then passes the result as `thinkingConfig` on the `NormalizedRequest` to the provider adapter.

**Types:**

```ts
type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh"

type ThinkingConfig =
  | "disabled"                                  // never send thinking params
  | "adaptive"                                  // let the model decide (Anthropic adaptive mode)
  | { level: ThinkingLevel; budgetTokens?: number }  // explicit level; budgetTokens overrides the settings table

// Settings-level budget lookup (maps level → token budget)
type ThinkingBudgetsSettings = Partial<Record<ThinkingLevel, number>>
```

**Resolution order** (later wins):

1. **Settings default** — `defaultThinkingConfig: ThinkingConfig` in harness settings. This is the harness-wide baseline before any mode or conversation applies.
2. **`ModeProfile.model.thinkingConfig`** — per-mode default. Plan mode might set `{ level: "high" }`; chat mode sets `"disabled"`. See [modes.md](../conversation-manager/modes.md).
3. **`conversation.routing.modelOptions.thinkingConfig`** — per-conversation runtime override, patchable at any time the conversation is idle. The user flips a control, it persists on the conversation resource, and takes effect on the next turn.

When `budgetTokens` is not specified on a `{ level }` config, the Pool looks it up from `settings.thinkingBudgets[level]` — a per-level token budget table configured once at the harness level. This keeps token counts out of per-conversation data.

**Sub-agent suppression.** Sub-agents inherit `"disabled"` as their thinking default regardless of what the parent conversation has configured, unless their spawned mode profile explicitly sets a `thinkingConfig`. Fork children should suppress thinking to control output token costs. The harness should not silently propagate a high-budget thinking config from a planning parent into every spawned sub-agent.

**Classifier and background calls.** Calls made by the Pool for non-user-blocking work (yolo/permission classification, background summarization, memory consolidation) should always resolve to `"disabled"` regardless of the conversation's `thinkingConfig`, since the quality uplift does not justify the latency and token cost for those tasks.

The provider adapter is responsible for translating the resolved `ThinkingConfig` into provider-specific wire params (e.g., Anthropic's `thinking: { type: "enabled", budget_tokens: N }` or `{ type: "auto" }` for adaptive). Nothing above the adapter sees provider-specific thinking shapes.

### Provider adapter interface

Provider adapters are the Pool's internal codec. They're not visible to anything outside the Pool. Interface:

```ts
interface ProviderAdapter {
  readonly id: string                                      // "anthropic" | "openai" | ...
  readonly authProfile: AuthProfile

  // Stream a request, emit normalized events
  call(model: ModelEntry, request: NormalizedRequest, signal: AbortSignal):
    AsyncIterable<NormalizedEvent>

  // Optional capability probes
  listAvailableModels?(): Promise<RemoteModelInfo[]>      // for dynamic discovery (Ollama, custom endpoints)
  validateAuth?(): Promise<boolean>
}
```

Two design notes:

- **The adapter normalizes events on the way out.** Token deltas, tool-call deltas, reasoning blocks, usage info, stop reasons all become a uniform `NormalizedEvent` stream. This is where wire format actually gets translated; nothing downstream of the adapter sees provider-specific shapes.
- **`listAvailableModels` is for dynamic providers** (Ollama running locally, vLLM endpoints, custom self-hosted). The Pool merges these into the registry on probe. Static providers (Anthropic, OpenAI) don't need this — their model list comes from the build-time `models.generated.ts`-style catalog.

A workable shape: a main provider file per SDK target plus per-provider adapter files under a `providers/` directory. What's needed beyond that is a normalization layer that emits a uniform event stream regardless of which adapter ran.

### What the Pool publishes

Onto the Communication Layer:

- `models/registry` — current registry snapshot; events on add/remove/cap-change.
- `model/{id}/state` — per-model state (idle / queued / generating / etc), in-flight count, rate-limit window, recent latency.
- `pool/health` — aggregate queue depth across models, error rates, budget remaining (per-account aggregated).
- Per-conversation: contributions to `conversation/{id}/events` (state transitions for the in-flight call), and to `conversation/{id}/state` (active model, projected cost, context-budget remaining).

---

## Alternatives

### Direct SDK calls (no Pool)

Just call `anthropic.messages.create({...})` from the runtime.

**When this works:** single-binary CLI, single user, single conversation at a time, single provider. A single-binary coding agent CLI is sized for this and gets away with it because its concurrency profile is "one foreground task, occasionally fanning out to a few sub-agents bound by user attention." If your harness fits that profile and you don't need failover, pool budget, or routing, the Pool is overkill.

**Why not as default:** every concern the Pool centralizes becomes a smear when this scales up. Failover lives wherever the next call site happened to need it; budget tracking is half-implemented in three different places; the answer to "what is the agent doing right now" requires correlating logs from multiple modules. Single-binary CLIs that grow into long-running agents almost always end up rebuilding the Pool from inside; building it as a layer up front is cheaper.

### External router service (LiteLLM, OpenRouter, custom proxy)

Pull all the Pool's concerns into a separate service that the harness talks to over a uniform API.

**When this works:** multi-tenant SaaS where many users / many harness instances need to share a routing policy, a budget, and a credential vault. Also: when the team building the harness doesn't want to own provider-adapter maintenance and would rather pay for someone else to keep up with the API churn. LiteLLM is the canonical example; OpenRouter is the hosted version.

**Why not strictly an alternative:** an external router is one *implementation* of the Pool, not a replacement for the layer. The harness still has a Pool — it's just thin and proxies most operations to the external service. The capability query, the lifecycle state machine, the per-call observability, the cache breakpoint decisions — all of those still live in-process even if dispatch is external. Treat external routers as a backend the Pool can use, not as a Pool substitute.

### Per-call provider selection at the runtime level

Let the runtime pick the model and provider for each call, with no centralized routing layer.

**When this works:** when there's exactly one call site (one place in the runtime that ever calls the model). Almost no real harness has this property; even single-binary CLIs typically have multiple call sites (main loop, sub-agent fan-out, background summary generators).

**Why not as default:** model choice is a routing decision and routing decisions want to live in one place. The moment two call sites exist, they drift on model selection, on retry policy, on failover behavior. The Pool exists so they can't.

---

## Anti-patterns

- **Hardcoded model strings throughout the runtime.** `model: "claude-sonnet-4-6-20260615"` in code is a load-bearing string with no escape hatch. Every model upgrade becomes a multi-file refactor; per-environment overrides require code branches. Push all model selection through capability query + named entries.
- **Provider as base class with model as parameter.** The conventional layout: `class AnthropicProvider { call(model, ...) }`. Looks clean; hides the fact that capability metadata, cost, and context window are *per-model* not per-provider, so they end up scattered. Invert it: model entries are the thing, provider is an attribute.
- **No queue, just inline calls under load.** Concurrent sub-agents all dispatch SDK calls in parallel; rate limits trigger; some calls fail, others succeed; the user sees inconsistent partial results. The Pool's queue is the difference between "fan out 20 sub-agents" working and falling over.
- **Budget enforcement as a middleware concern.** Putting budget on a per-call interceptor sounds modular but means each call site needs to wire the interceptor in, the interceptor doesn't have aggregate visibility across concurrent calls, and global limits become impossible. Budget belongs at the Pool's dispatch boundary.
- **Hidden global LLM client.** A module-level singleton `getClient()` that returns a configured SDK instance. Convenient until you need per-conversation auth profiles, per-conversation routing overrides, or even a second concurrent conversation in one process. Force every call to go through the Pool, which holds the configuration.
- **Provider-specific events leaking up.** If the runtime sees `event.type === "content_block_delta"` (Anthropic-shaped) for one provider and `event.choices[0].delta` (OpenAI-shaped) for another, the adapter layer hasn't normalized. Push the normalization into the adapter; everything above the Pool sees one event shape.
- **Failover that silently downgrades capability.** Substituting a smaller model when the requested one fails, without the caller opting in, produces worse output that the caller doesn't know about. Default off; explicit opt-in only.
- **Cache breakpoints chosen by call sites.** The model knows where the cacheable prefix ends; the call site usually doesn't. If every call site is computing its own cache directives, you'll see inconsistent cache hit rates and missed savings. The Pool decides where to cache based on request structure and model capability; call sites just provide the request.

---
