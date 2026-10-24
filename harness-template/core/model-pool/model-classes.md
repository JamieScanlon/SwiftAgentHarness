# Model Classes — Contracts, Roles, and Selection

> Sibling page of [model-pool/README.md](./README.md). The README defines the Pool (registry, capability query, scheduler, failover, budget, cache) with a chat-shaped `ModelEntry`. This page generalizes the registry to every kind of model the harness drives: chat and reasoning LLMs, decision models, embedders, rerankers, media generators, speech models, realtime sessions, and document parsers. It also defines how the harness chooses a model for a job. The wire protocol for decision models is broken out in [providers/decision-models.md](../../backends/providers/decision-models.md).

## TL;DR

**Classify a model by its call contract first, describe it by capability facets second, and select it by role and policy third.** "Is it an LLM?" is the wrong first question. The useful first question is "what is the shape of a call to it?" Is it messages in and a token stream out? A state plus closed questions in and calibrated probabilities out? Inputs in and vectors in a named space out? A job you submit and poll? A duplex session with a lifetime? Each answer is a different **contract** with its own request, response, interaction pattern, pricing unit, failure modes, and Pool lifecycle. One model can expose several contracts. For example, a general LLM can also be served behind a decision endpoint.

The prescriptive shape:

1. **Eight contracts.** `generate`, `decide`, `embed`, `rerank`, `render`, `transcribe`, `session`, `parse`. Moderation is `decide` with a fixed question set. Computer use, hosted search, and image *output* from a chat model are *features* of `generate`, not separate contracts.
2. **Interaction pattern is its own axis.** `unary | stream | job | session | batch`. Image rendering is unary at one vendor and a polled job at another. The contract stays the same while the pattern differs.
3. **Model vs. offering.** Provider-neutral facts live on the model. Limits, price, and feature support live on the `ProviderBinding` that serves it, and the binding may override the model downward.
4. **Output guarantee is a ranked capability.** `free-text < json-mode < schema-strict < logprobs < calibrated-distribution`. A "classify this" job asks for a guarantee, not a model family.
5. **Cost is a unit-typed vector**, not two per-token numbers. Units include image, second-at-resolution, minute, character, page, query, and session, plus processing tiers.
6. **Roles are the selection surface for internal callers.** Callers never name a model. Compaction asks for `compactor`, the permission gate asks for `gatekeeper`, and memory recall asks for `embedder:<space>`. A role binds a contract, a minimum guarantee, a query, a priority class, and a fallback/cascade policy.
7. **The selection pipeline is fixed.** Resolve the role, hard-filter on contract and facets, rank by policy, cascade at most one stage, fall back only inside the compatibility group, and emit a route receipt.
8. **Every model call goes through the Pool, whatever its contract.** Scheduler, budget, lifecycle, failover, and observability generalize across contracts. An auxiliary call that constructs its own client is a bug, not an optimization.

---

## Why the chat-shaped entry stops working

The README's `ModelEntry` is correct for what it covers. Its `capabilities` block (tools, vision, reasoning, prompt cache, tool-choice ladder) is a precise description of a **generative chat model**. It breaks the moment the harness needs any of the following, and by late 2026 a non-toy harness needs most of them:

- **A calibrated yes/no or multiple-choice answer in ~100 ms.** Decision models (a hosted classifier family that popularized the *SystemOne* request shape, plus OpenAI's Decisions API, Cloudflare's, Microsoft's, and open-weight deciders served by llama.cpp, vLLM, and Ollama) take a `state` and typed questions and return probability distributions. They have no messages, no streaming, and no generation, and they are billed on input tokens only. Gateways reject them on chat endpoints.
- **Vectors that must stay comparable.** An embedder's output is only meaningful against other vectors from the same embedding space. A newer version of "the same" embedding model is frequently a different space. Failover by capability, which is correct for chat, silently corrupts a vector store.
- **Media that takes minutes.** Video generation is always a submitted job with polling or a webhook, and the artifact has a retention window measured in minutes to days. Some image APIs are also jobs.
- **A conversation that is a connection.** Realtime speech-to-speech is a stateful WebSocket or WebRTC session with ephemeral client secrets, a hard session lifetime, and resumption tokens. It is not a long streaming call.
- **Prices that are not tokens.** Per image, per output second at a given resolution, per minute of audio, per 1K characters, per page, per query, per session. Processing tiers (batch, flex, fast) and long-context or regional surcharges apply on top.

The ecosystem has already converged on this shape. The most rigorous provider SDK spec now defines ten separate model interfaces, each with its own call method. Gateway registries classify by endpoint family (`chat`, `embedding`, `rerank`, `audio_transcription`, `audio_speech`, `image_generation`, `video_generation`, `realtime`, `ocr`, `moderation`, `evaluation`). Model directories now filter by output kind, including `decisions`, and local runtimes expose a `decision` capability. A harness that keeps one chat-shaped entry ends up bolting `generateImage` onto the chat adapter protocol, leaving `embedding` as a capability tag nothing dispatches on, and hard-wiring auxiliary jobs to a specific local client because the Pool had no way to express them.

---

## Recommendation

### Contracts: classify by the shape of the call

| Contract | Call shape | Typical interaction | Output | Native pricing unit | Examples (late 2026) |
|---|---|---|---|---|---|
| `generate` | messages (+tools, +media) → content blocks, tool calls | stream, unary, job (background mode), batch | text, tool calls, reasoning; some models also image or audio | tokens (several kinds) | Claude, GPT, Gemini, Grok, Mistral, local LLMs |
| `decide` | `state` + typed questions → per-question distributions | unary, all-or-nothing | distribution, probability, ordinal score, bounding box, refusal | input tokens only | SystemOne-shaped deciders, OpenAI Decisions, open-weight deciders |
| `embed` | inputs[] (+role: query/document) → vectors | unary, batch, job (bulk) | vectors in a named space | input tokens | OpenAI, Gemini, Voyage, Cohere, Jina, local |
| `rerank` | query + documents[] → `[{index, score}]` | unary | relevance scores | per query or per token | Cohere, Voyage, Jina, local pooling models |
| `render` | prompt (+reference media, +mask) → media artifact | unary, stream (partials), job | image, speech, music, sound, video | per image / pixel / second@res / character / token | image APIs, TTS, music, video generators |
| `transcribe` | audio → text (+timestamps, speakers) | unary (file), stream (live partials + endpointing) | text, segments | per minute or second | STT services, on-device speech |
| `session` | duplex event stream with a lifetime | session (WebSocket / WebRTC) | audio + text deltas, tool calls | per minute, or per audio token | realtime voice, live translation |
| `parse` | document or image → structured text | unary, job | markdown, blocks + boxes, tables, confidences | per page | OCR and document-AI services |

Rules that keep the taxonomy small:

- **Moderation and guardrail classifiers are `decide` with a fixed question set.** They return per-category scores for categories the vendor defines. Model them as a `decide` profile whose `questionSet: "fixed"` names the vendor taxonomy. Policy treats them the same way as any other decider: thresholds keyed to a pinned version.
- **Computer use, hosted web search, hosted code execution, and image output from a chat model are features of `generate`.** Every major vendor has folded computer use into general models as a client-side tool. No separate "computer-use model" kind remains at the major labs. See [computer-use](../../backends/computer-use/).
- **Speech translation is a `session`.** File transcription is `transcribe`, live transcription with endpointing is `transcribe` with `interaction: stream`, and duplex voice is `session`.
- **An agent served behind a model id is a `generate` offering with `interaction: job`** when you call it as a one-shot. When it runs multi-step with its own tools and returns a report, it is better modelled as a Sub-Agent Pool transport. Pick one per integration and record the choice. Do not make it both.

### The descriptor: contracts, facets, offering

```ts
type ModelContract =
  | "generate" | "decide" | "embed" | "rerank"
  | "render" | "transcribe" | "session" | "parse"

type MediaType =
  | "text" | "json" | "image" | "pdf" | "audio" | "video"      // inputs and outputs
  | "tool-calls" | "vector" | "distribution" | "bbox" | "segments"

type Interaction =
  | { kind: "unary" }
  | { kind: "stream"; partials?: "deltas" | "snapshots" }
  | { kind: "job"; poll: boolean; webhook: boolean; artifactTtlSec?: number; typicalSec?: [number, number] }
  | { kind: "session"; transports: ("websocket" | "webrtc")[]; maxLifetimeSec?: number; resumable: boolean; clientSecrets: boolean }
  | { kind: "batch"; discount?: number }

type OutputGuarantee =
  | "free-text" | "json-mode" | "schema-strict" | "logprobs" | "calibrated-distribution"

type ContractProfile = {
  contract: ModelContract
  surface: string                   // wire surface the codec speaks: "anthropic-messages", "openai-responses",
                                    // "systemone", "openai-decisions", "openai-images", "realtime-ws", ...
  interaction: Interaction[]        // what this offering supports; the request picks one
  input: MediaType[]
  output: MediaType[]
  guarantee: OutputGuarantee        // strongest guarantee the surface can deliver
  features: Record<string, FeatureSupport>   // versioned keys, see below
  limits: ContractLimits
}

type FeatureSupport = { supported: boolean; version?: string; params?: Record<string, unknown> }

type ContractLimits = {
  contextTokens?: number; maxOutputTokens?: number
  maxItemsPerCall?: number          // embeddings, images, questions per decide call
  maxOptions?: number; scoreLevels?: [number, number]   // decide
  maxDurationSec?: number; resolutions?: string[]       // render / video
  maxImageEdgePx?: number; maxImageTokens?: number      // vision input caps
  concurrentJobs?: number
}

type ModelEntry = {
  id: string; family: string; displayName: string
  lifecycle: {
    status: "preview" | "active" | "deprecated" | "retired"
    retiresAt?: string
    aliasOf?: string                // set when this id is a moving alias; aliases never carry tuned thresholds
  }
  compatGroup?: string              // embedding space id, or a declared "same behaviour" group; see below
  contracts: ContractProfile[]      // one model, possibly several contracts
  cost: PriceVector
  performance: PerformanceProfile   // observed, per contract; never declared
  locality: Locality
  routing: { roles: string[]; useClasses: string[]; rateLimit?: RateLimit }
  providers: ProviderBinding[]      // a binding may override contracts/limits/cost/features downward
}
```

The README's existing `capabilities` block is not wrong. It becomes the `features` and `limits` of the `generate` contract: `tools`, `parallelToolCalls`, `toolChoice` ladder, `reasoning`, `promptCache`, `structuredOutput`, and the vision/audio input flags, which become entries in `input`. Migration is mechanical. A registry that reads the old shape can synthesize a single `generate` profile.

**Features are versioned keys, not booleans.** A vendor's computer-use toolset, a server-side compaction strategy, and a context-editing mode each come in dated versions with different semantics. `features["computer-use"] = {supported: true, version: "toolset-2026-08", params: {coordinates: "pixels", maxEdgePx: 2576}}` lets the codec emit the right tool definition and lets the Context Engine know how to prune. A bare `computerUse: true` cannot do either. The same applies to `decide` features: `questionTypes: ["yes-no", "choice", "score", "box"]` and `imagesEncoding: "assets" | "images-array" | "parts"`.

**Model vs. offering.** Put provider-neutral facts on the model: family, lifecycle, contracts the weights support, and compat group. Put serving facts on the binding: surface, actual limits, price, region, and which features this endpoint honors. The same decision dialect is capped at 64 questions per call on some local servers and has no stated cap at the reference hosted API. The same chat model honors `required` tool choice through its vendor and silently ignores it through a thin compatibility proxy. The README already applies this downward-override rule to the tool-choice ladder. Extend it to every facet.

### Output guarantee is a ranked capability

```
free-text  <  json-mode  <  schema-strict  <  logprobs  <  calibrated-distribution
```

Many harness jobs are really closed questions: "is this tool call safe to auto-approve?", "which skill applies?", "does this sentence state a durable fact?", "which model should take this turn?" Those jobs should **ask for `calibrated-distribution` and accept a downgrade explicitly**:

1. A `decide` offering yields a calibrated distribution.
2. A `generate` offering with `logprobs` on a single constrained token yields a usable but uncalibrated distribution. Mark it `calibrated: false`.
3. A `generate` offering with `schema-strict` yields an answer with no probability. Mark confidence `unavailable` so every threshold-based policy falls through to its conservative branch.

The result type records which rung produced it. A threshold tuned on rung 1 must never be applied to rung 3. See [decision-models § Policy](../../backends/providers/decision-models.md#policy-thresholds-bands-escalation).

### Cost as a unit-typed vector

```ts
type PriceUnit =
  | "input-token" | "output-token" | "cache-read-token" | "cache-write-token" | "reasoning-token"
  | "audio-input-token" | "audio-output-token" | "image-input-token" | "image-output-token"
  | "image" | "megapixel" | "second" | "minute" | "character" | "page" | "query" | "request" | "session"

type PriceComponent = {
  unit: PriceUnit
  usd: number; per: number                    // e.g. { unit: "image", usd: 0.04, per: 1 }
  when?: { tier?: "standard" | "batch" | "flex" | "fast"; contextAbove?: number;
           resolution?: string; quality?: string; region?: string }
}
type PriceVector = PriceComponent[]

interface CostEstimator {
  // per contract: tokens for generate/decide/embed, items×resolution for render, minutes for session…
  project(entry: ModelEntry, binding: ProviderBinding, request: PoolRequest): { usd: number; basis: string }
  settle(entry: ModelEntry, binding: ProviderBinding, usage: NormalizedUsage): number
}
```

`NormalizedUsage` grows matching fields: images, seconds, characters, pages, and queries, alongside the token counts. Budget enforcement in the README is unchanged in shape: project at `dispatching`, settle at `done`. It now works for a $0.40-per-second video job and a $0.00004 decision call alike. An entry with no price component for the units a request will consume projects as *unknown*. The budget policy decides whether unknown is allowed. Never treat unknown as zero.

### Roles: the selection surface for internal callers

The README's capability query is the right primitive, but internal callers should not each write their own queries. They ask for a **role**, a named job the harness performs repeatedly. The host binds roles to models once.

```ts
type RoleBinding = {
  role: string                       // well-known ids below; hosts may add their own
  contract: ModelContract
  minGuarantee?: OutputGuarantee
  query: ContractQuery               // hard needs + preferences over contract profiles (below)
  pin?: string                       // explicit model id; must satisfy contract + minGuarantee
  fallback?: string[]                // ordered ids; for compat-bound roles, same compatGroup only
  cascade?: { to: string; when: DeferralCondition }    // at most ONE escalation stage; for decide roles,
                                                       // derived from the consumer's DecisionPolicy.escalate
  priority: "foreground" | "background"
  thinking?: ThinkingConfig          // see thinking rule below
  locality?: "any" | "local-only" | "no-vendor-retention"
  budget?: { maxUsdPerCall?: number; maxLatencyMs?: number }
}

type ContractQuery = {
  contract: ModelContract
  interaction?: Interaction["kind"]
  input?: MediaType[]; output?: MediaType[]              // required media (subset match)
  minGuarantee?: OutputGuarantee
  features?: Record<string, { version?: string; params?: Record<string, unknown> }>  // must be supported
  limits?: Partial<ContractLimits>                       // minimums the request needs
  prefer?: { roles?: string[]; useClass?: string; family?: string; maxProjectedUsd?: number; maxP50Ms?: number }
  excludeFamilies?: string[]
}
```

`ContractQuery` is the README's `ModelQuery` lifted to contract profiles. The README's `needs: Partial<ModelEntry["capabilities"]>` still works for `generate`. The registry keeps `capabilities` as a **derived read-only view** of each entry's `generate` profile, and a legacy `ModelQuery` compiles to `ContractQuery {contract: "generate", features/limits/input from needs}`. Existing callers keep working, and new callers use contracts.

**Thinking rule for roles.** `decide` roles have no thinking: decision models don't reason, and emulated deciders resolve thinking to `"disabled"`. `gatekeeper`, `guard`, and any role feeding a permission or safety decision are **always** `"disabled"`, whatever the binding says. The README's rule for classifier and background calls stands. Other background roles (`background-small`, `compactor`, `recall`) default to `"disabled"` and may opt in only through an explicit `thinking` on the binding.

Well-known roles. A harness need not bind all of them. An unbound role falls back to its listed default.

| Role | Contract | Used by | Default when unbound |
|---|---|---|---|
| `main` | generate | Agent Runtime main loop | required |
| `subagent` | generate | Sub-Agent Pool spawns without a model ref | `main` |
| `background-small` | generate | titles, away summaries, tool-use labels, personality nudges | cheapest `generate` with `tools: false` acceptable, non-mandatory reasoning |
| `compactor` | generate (or a vendor compaction feature) | Context Engine compaction | `background-small`, then `main` |
| `recall` | generate | Memory pre-reply recall selector | `background-small` |
| `gatekeeper` | decide | Tool System classifier-assisted gating | none, so the layer is off |
| `guard` | decide | input/output guardrail battery, tool-output injection probe, computer-use per-action intent check | none: guardrails and the probe are off. Computer use treats an unbound guard as "confirm interact actions on shared targets"; see [computer-use](../../backends/computer-use/README.md#safety-is-layered-not-a-single-gate). |
| `router` | decide | Pool rank stage, Sub-Agent / skill selection | none, so static policy applies |
| `skill-filter` | decide | Context Engine skill pre-filter | none |
| `memory-gate` | decide | Memory write gating | none |
| `embedder:<space>` | embed | Memory and conversation search, RAG | none, so keyword search applies |
| `reranker` | rerank | recall, attachment retrieval | none |
| `parser` | parse | Context Engine attachment inlining for scans and PDFs | `generate` with `pdf` / `image` input |
| `vision-describe` | generate (image in) | describe images for models without vision | any vision `generate` |
| `transcriber` / `speaker` / `voice-session` | transcribe / render(audio) / session | Interface voice slots | none |
| `image` / `video` | render | Tool System media tools | none, so the tools are unregistered |
| `computer-use` | generate + `computer-use` feature | computer-use specialist sub-agent | `main` if it has the feature |
| `grounder` | generate (image in → coordinates) | computer-use perception fallback | none |

This table is the missing **"cheap-and-fast slot"** that sibling pages already refer to ([tool-use-summaries](../tool-system/tool-use-summaries.md), [personality](../../surfaces/interface/personality.md), [compaction](../context-engine/compaction.md)): it is `background-small`. The "auxiliary-client fallback chain" in [providers](../../backends/providers/README.md#aux-model-patterns-are-a-pool-concern-not-a-provider-concern) is a role's `fallback` list.

**Resolution order for a role** (later wins): built-in default → harness settings `roles` → `ModeProfile.model.roles` patch → conversation `routing.roles` patch → per-call explicit `pin`. This is the same three-layer chain the README uses for `thinkingConfig`, extended to every role. The mode-profile model slice changes from "a query and a fallback for the main model" to "a partial map of role bindings." `main` is just the role most modes override.

**Roles carry trust.** A role used on private memory can be `locality: "local-only"`. A `gatekeeper` that sees tool arguments containing secrets can be `no-vendor-retention`. The Pool enforces this as a hard filter, not a preference. A local-only role with no local candidate fails closed with a typed error. It does not fall through to a cloud model.

### The selection pipeline

Every Pool call follows these six steps, whether it arrives as a role, a query, or a pinned id:

1. **Resolve** the role binding (or wrap a bare query or id in an anonymous binding).
2. **Hard-filter.** Keep only candidates that support the contract, carry the interaction pattern the caller needs, cover the input and output media, meet `minGuarantee`, satisfy the feature keys and limits for this request (context size, item count, question types, resolution), pass locality and lifecycle (no `retired`; `deprecated` only if pinned), and stay inside the compatibility group when the role is compat-bound.
3. **Rank by policy.** Apply the role's explicit preference order. If a `router` role is bound, add a decision-model ranking: a `choice` question over the candidate ids or over named policies, with calibrated probabilities. Fold in projected cost from the price vector and the request, observed p50 latency against the role's latency budget, and **prompt-cache warmth**. Moving a subtask from the session model to a "cheaper" model can cost more when the session model's cache is warm and the subtask shares its prefix.
4. **Cascade at most one stage.** If the role declares `cascade`, run the cheap candidate first and escalate when its deferral condition matches (low confidence, a probability in an ambiguous band, refusal, or confidence unavailable). Published results on cascades show a two-model cascade reliably helps and a third stage almost never does. Use a deferral signal that is free, meaning the first stage's own calibrated probability. A signal that needs extra generations, such as self-consistency or a judge call, is not free.
5. **Fall back** only on availability-class errors (transient, rate-limited, credential-exhausted, model-not-found), and only to candidates that passed step 2. For compat-bound roles (`embedder:*`, and any `decide` role with tuned thresholds) the fallback list is restricted to the same `compatGroup`. A threshold-bearing decide role's fallbacks must also have bands in the consuming policy, or their answers are treated as untuned (see [decision-models § Policy](../../backends/providers/decision-models.md#policy-thresholds-bands-escalation)). Quality is never a fallback reason. Quality escalation is the cascade's job.
6. **Emit a route receipt** with the call's lifecycle events:

```ts
type RouteReceipt = {
  callId: string; role?: string; contract: ModelContract
  requested: string                  // role, query hash, or id as asked
  resolved: { modelId: string; versionServed?: string; bindingId: string; surface: string }
  aliasResolved?: { alias: string; to: string }
  tier: { requested?: string; effective?: string }
  rankedOut?: { modelId: string; reason: string }[]     // top few, for "why not X"
  cascade?: { escalated: boolean; reason?: string }
  fallback?: { from: string; reason: FailoverClassification }[]
  guarantee: OutputGuarantee         // rung actually delivered
  costUsd: number; latencyMs: number
}
```

Receipts make "why did the gate auto-approve this with a local model last Tuesday?" answerable. They are the per-call record that [observability](../../cross-cutting/observability/) exports and that surfaces render as "answered by X (fallback from Y)."

### Who calls which contract

The Pool owns every model call. Callers differ, and that settles the "is image generation a provider slot or a tool?" question that the providers page leaves open.

| Contract | Harness-internal callers (no model involvement) | Model-invokable wrappers (Tool System entries) |
|---|---|---|
| generate | Agent Runtime, Sub-Agent Pool, Context Engine (compaction), Memory (consolidation, recall) | delegate tools (via Sub-Agent Pool) |
| decide | Tool System gating, Context Engine skill filter, Memory write gate, Pool router, computer-use intent check, Interface voice (voicemail detection, voice UI intent) | optional `classify` tool for agent-authored checks |
| embed / rerank | Memory recall, conversation search, attachment retrieval | `memory_search` (indirectly) |
| render | — | `image_generate`, `speak`, `video_generate` |
| transcribe / session | Interface voice slots | — |
| parse | Context Engine attachment inlining | `read_document` (indirectly) |

The rule: **the provider slot registers an offering for a contract; the Pool resolves and dispatches it; a tool is only a model-facing wrapper that calls the Pool by role.** The `image_generate` tool never talks to a provider. It asks the Pool for the `image` role, receives a blob reference, and returns it through [result formatting](../tool-system/result-formatting.md).

### Pool mechanics generalize per interaction pattern

The README's state machine is the `stream` pattern. The other patterns get their own, published on the same `model/{id}/state` topic:

```
unary:    queued → dispatching → awaiting → done | errored | cancelled
job:      queued → submitting → submitted → running → succeeded → fetching → done
                                                 └→ failed | expired | cancelled
session:  queued → minting-secret → connecting → live ⇄ resuming → closing → closed
                                                    └→ errored
```

- **Scheduler.** Keep per-binding concurrency caps for every contract. Jobs also count against the vendor's active-job cap (some image APIs allow about two dozen active tasks). Sessions count against concurrent-session limits and are long-held, so they get their own lane and do not block the foreground `generate` queue.
- **Jobs survive the caller.** The Pool persists submitted job handles (operation id, polling URL, webhook id) to [persistence](../../backends/persistence/) so a restart resumes polling. Artifacts are fetched into the blob store before `artifactTtlSec` lapses. Signed result URLs that expire in minutes are common, so "fetch on success" is part of the contract, not a caller's afterthought.
- **Sessions are leases.** A session has a lifetime. The Pool tracks `timeLeft` (from vendor go-away signals), mints ephemeral client secrets when a surface connects directly, and owns resumption. Budget is charged per elapsed unit while live.
- **Cache.** `decide`, `embed`, and `rerank` against a pinned version are deterministic enough to response-cache by `(modelVersion, request hash)`. This is where the README's opt-in response cache earns its keep. Embedding caches are keyed by `(space, dims, dtype, input hash, role)`.
- **Lifecycle and aliases.** Resolve moving aliases (`*-latest`, `*-preview`) to a versioned id at dispatch and record both in the receipt. Roles that carry tuned thresholds should pin versions. An alias move is then an explicit config change with a re-tuning step, not a silent behavior change.

### Embedding spaces are compatibility groups

- `compatGroup` on an embedder is its **embedding space id**. Vectors are stored with `{spaceId, dims, dtype, normalized}`. A vector from another space is not comparable, even when dimensions match.
- Some vendor families deliberately share one space across sizes, so the large model embeds documents and the small model embeds queries. Declare that by giving all members the same `compatGroup`. Asymmetric query/document roles then become a legal fallback.
- Matryoshka truncation (`dims` per call) is a request parameter validated against `limits`. Re-normalize when the vendor does not.
- Changing a role's embedder is a **migration**, not a config flip. Schedule a background re-embed job and dual-read until it completes. Never fail over across spaces on error. Degrade to keyword search and say so in the receipt.

---

## Alternatives

### Flat capability flags on one chat-shaped entry

Add `embedding: true`, `imageGeneration: true`, and `decision: true` flags to the existing entry and route on them.

**When this works:** a harness that uses exactly one non-chat model kind, typically embeddings, and treats it as a side channel with a dedicated client.

**Why not as default:** a flag says a model *can* do something but not *how to call it*. Every flag ends up needing a bespoke method on the adapter protocol (`generateImage`, `embed`, `decide`), every decorator in the Pool has to forward each one, and the cost model stays per-token. The flags exist, but nothing dispatches on them.

### Modality taxonomy (input → output)

Classify as `text→text`, `text+image→text`, `text→image`, `audio→text`, and so on, as model hubs and some directories do.

**When this works:** discovery and search UIs, where a human browses for "something that makes images."

**Why not as default:** it is lossy in exactly the places that matter. Transcription and chat both output text, and embeddings and rerankers both output numbers. Decision models output a distribution that no modality list names. It also says nothing about interaction pattern or price unit. Keep media sets as a *facet* of each contract profile, not as the primary key.

### Separate pools per kind

An `EmbeddingPool`, a `DecisionPool`, a `MediaPool`, each with its own registry and scheduler.

**When this works:** a library that ships one kind and wants no dependency on the rest.

**Why not as default:** the Pool's value is that budget, failover, concurrency, lifecycle, and observability have one home. Per-kind pools re-implement all five, and global budget becomes impossible because no pool sees the others' spend. One registry with contract profiles, plus per-contract codecs and state machines, gets the separation without the duplication.

### Learned or LLM router as the primary selector

Send every request to a trained router (preference-trained strong/weak routers, policy routers that map a request to a written domain-action policy in ~50 ms, or a hosted auto-router ranked by aggregate usage) and let it pick from the whole registry.

**When this works:** multi-tenant gateways with large, diverse traffic and the eval data to train or tune the router.

**Why not as default:** it is opaque, it needs data a single-user harness does not have, and it cannot enforce hard constraints such as locality, embedding space, or tuned thresholds. **The piece worth borrowing:** run it as the rank stage (step 3) *after* the hard filter. A calibrated decision model asked "which of these policies fits this turn?" is a cheap, inspectable router.

### Gateway-owned taxonomy

Let an external gateway's `mode` field and price schema be the registry, and proxy everything through it.

**When this works:** the team already runs a gateway for budget and keys across many apps.

**Why not as default:** the gateway is a backend the Pool can use (see the README's "External router service" alternative), not the Pool's data model. Gateway modes are endpoint families, and `chat` vs `responses` is an API-surface distinction, not a kind of model. **The piece worth borrowing:** the gateway price schema's unit vocabulary is the most complete published list of pricing units. Align `PriceUnit` with it so catalogs can be imported.

---

## Anti-patterns

- **Classification through a chat model and a JSON schema by default.** The answer arrives with no probability, so thresholds are meaningless and "confidence" is whatever the model wrote. Ask for `calibrated-distribution`, accept a downgrade explicitly, and mark the rung in the result.
- **Auxiliary calls that build their own client.** A compaction summarizer or recall selector that instantiates a local-model client directly bypasses budget, failover, scheduling priority, auth profiles, locality policy, and the route receipt. It also pins the harness to one runtime. Every model call goes through the Pool by role.
- **Use classes nobody populates.** A soft `useClasses` hint that no catalog fills and no caller agrees on never matches, so ranking silently falls through to latency. Roles are the explicit, host-bound version. Keep `useClasses` only as catalog metadata that informs default role bindings.
- **Silent embedder substitution.** Failing over from one embedding model to "a similar one" returns well-formed vectors that are garbage against the stored index. Embedders are compat-bound, with no cross-space fallback ever.
- **Per-token-only cost.** Budgeting a video job or a realtime session in tokens either blocks it (unknown cost treated as infinite) or lets it run unmetered (unknown treated as zero). Use unit-typed prices and an explicit unknown-cost policy.
- **Tuned thresholds on moving aliases.** A gate tuned at 0.85 on version N that silently starts answering from version N+1 through a `-latest` alias has an unknown false-approve rate. Pin versions on threshold-bearing roles and record the served version.
- **A mandatory-reasoning model as the small-fast model.** A cheap-per-token model that always thinks can be slower and costlier per call than a mid-tier model with thinking off. The filter for `background-small` should exclude `reasoning: "required"` unless explicitly pinned.
- **Treating a realtime session as a long stream call.** Sessions have lifetimes, resumption, ephemeral secrets, and per-minute billing. Pushing them through the `stream` state machine loses go-away handling and leaks minutes.
- **Cascades deeper than two, or deferral that costs generations.** A third stage rarely improves accuracy. A deferral score computed by sampling the first model several times, or by asking a judge, often costs more than calling the strong model directly.
- **Tools that call providers.** An `image_generate` tool that holds its own vendor client duplicates the Pool and escapes budget. Tools call the Pool by role.

---

## Cross-references

- [Model Pool README](./README.md): registry, query, scheduler, failover, budget, cache. This page generalizes its `ModelEntry` and lifecycle.
- [providers/decision-models.md](../../backends/providers/decision-models.md): the `decide` contract's wire codecs (SystemOne, OpenAI Decisions, LLM emulation), calibration, and policy bands.
- [providers/README.md § Capability scope as parallel slots](../../backends/providers/README.md#capability-scope-as-parallel-slots): provider slots register offerings for the contracts defined here.
- [backends/computer-use](../../backends/computer-use/): the `computer-use` feature, the `computer-use` and `grounder` roles.
- [conversation-manager/modes.md](../conversation-manager/modes.md): mode profiles carry partial role bindings.
- [tool-system/permissions.md § Classifier-assisted gating](../tool-system/permissions.md#classifier-assisted-gating-optional-layer): the `gatekeeper` role's consumer.
- [surfaces/interface/voice.md](../../surfaces/interface/voice.md): the `transcriber`, `speaker`, and `voice-session` roles.
- [memory/pre-reply-recall.md](../memory/pre-reply-recall.md): the `recall`, `embedder:<space>`, and `reranker` roles.
- [observability](../../cross-cutting/observability/): route receipts as the per-call usage and attribution record.
