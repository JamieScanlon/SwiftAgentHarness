# Providers

## TL;DR

A **provider** is a plugin that knows how to talk to one external inference endpoint — its auth, its model catalog, its wire format, its quirks. Providers are **not** the unit of model selection (the Model Pool is); they are **wire-codec backends** the Pool dispatches to. Treat each provider as a self-contained extension with a static manifest, a runtime adapter, and a small set of named hooks the Pool calls into.

The prescriptive shape:

1. **Manifest-validated plugin** at `extensions/<provider>/`, declaring `providerEndpoints`, `providerAuthChoices`, `modelSupport.modelPrefixes`, and `cliBackends` without executing plugin code. Validates statically; surfaces in `pluginsInspect`.
2. **Auth profiles with cooldown rotation** as the credential-multiplexing primitive. Several keys per provider, marked exhausted on 402/429, cooled-down with backoff.
3. **Canonical model-ref form `provider/model-id`**, parsed in one place, normalized via the provider's optional `normalizeProviderModelId` hook.
4. **Stable-prefix / cache-boundary contributions** to the system prompt, never replacement. The provider plugin owns its prefix (cached) and its dynamic suffix (below the boundary marker).
5. **Named-section prompt overrides** as the seam for model-family tuning (GPT-5 vs GPT-5-mini vs Sonnet differ on tool-call style, persona, output verbosity). Cleaner than legacy `before_prompt_build` hooks.
6. **Capability scope as parallel slots** — text inference, CLI inference backends, speech, realtime voice, media-understanding, image-gen, video-gen, music-gen, web-fetch, web-search are *separate* registration slots, not flavors of one provider type.
7. **Tool-schema normalization at the runtime seam**, not at every call site. One provider rejects `anyOf`; the adapter knows; everything above it sees the same shape.
8. **Failover signals raised by the provider, decided by the Pool.** The provider classifies an error (`transient` / `credential-exhausted` / `permanent`); the Pool decides whether to retry, rotate auth profile, fail over to another binding, or surface. The split is load-bearing — only the Pool has the concurrent visibility to make rotation decisions correctly.
9. **Opt-in lifecycle and two packaging shapes.** A provider is *available* (installed) but contributes nothing until *registered* (the user adds an auth profile or confirms a local base-URL); *disabled* retains config while excluded. Orthogonally, a provider plugin is packaged either as **code** (an adapter compiled/loaded into the host) or as **configuration** (data that parameterizes a generic adapter the host already ships) — the latter giving runtime extensibility with a code-free trust boundary.

The recommended shape treats provider registration, credential multiplexing, model selection, and capability scope as four orthogonal concerns. Design evidence: a generated `MODELS` registry with a uniform event stream is the right wire-codec discipline; a plugin manifest with capability-slot model is the right registration shape; a credential pool with per-task auxiliary fallback chain is the right multi-key + multi-task discipline; an SDK-instantiation-time provider switch (env-var-driven SDK swap) is the *anti-pattern* — it works for a small fixed set of SDKs but fails the moment you want runtime per-call routing or more than a few providers; three-tier profile lookup (exact-model > provider > default) is the right configuration-resolution shape; a flat capability scope (text-only) is workable but limits extensibility.

For the layer that *uses* providers, see [`../../core/model-pool/`](../../core/model-pool/). For the auth-storage backing this page assumes, see [`../persistence/`](../persistence/).

---

## How this fits the architecture

The architecture lock-in is unambiguous: **models, not providers, are the base abstraction.** That commits us to a specific layering — the question this page answers is what *exactly* a provider is, given that the Model Pool sits above it.

### The four-layer split

Separate four orthogonal concerns — this resolves a category error that most harnesses conflate somewhere:

| Layer | What it owns | Example values |
|---|---|---|
| **Provider** | Auth, endpoint, model discovery, model-ref naming | `openai`, `anthropic`, `bedrock`, `ollama`, `openrouter` |
| **Model** | The picked id within a provider | `claude-sonnet-4-6`, `gpt-5.5`, `gemini-3-pro` |
| **Agent runtime** | The prepared model loop the harness chose | `native` (embedded), `app-server` (external process), `acp` (external protocol) |
| **Channel** | Where the message originates | CLI, Slack, Telegram, Discord, ACP, trigger |

The product of these is the addressable thing. `openrouter/anthropic/claude-sonnet-4-6 + native-runtime + slack-channel` is unambiguous; `anthropic/claude-sonnet-4-6 + app-server-runtime + cli-channel` is a different addressable. None of the four is reducible to another. The SDK-instantiation-time env-var approach collapses *provider* and *runtime* into one switch — and pays for it the moment you want a Bedrock model and an Anthropic model in the same process. A `"provider:model"` string carries provider+model only, deferring runtime to the framework — workable but means the runtime is implicit in whichever model subclass was resolved.

### What lives here vs. on Model Pool

The Model Pool [recommendation page](../../core/model-pool/) commits us to: *"Provider adapters live inside the Pool as wire codecs — they translate 'this model wants this request' into 'this provider's wire format.' Nothing else in the harness should know about providers."* That's the boundary.

This page covers the **plugin shape** — what a provider plugin *is*, what hooks it exposes, what its manifest declares, how it's discovered, how its catalog feeds the registry. Concerns that *use* providers but don't live in them go on the Model Pool page:

| Concern | Owner | Why |
|---|---|---|
| Provider plugin manifest, file layout, registration | **Providers (this page)** | Static shape of the backend |
| Auth profiles, credential storage, OAuth flows | **Providers (this page)** | Per-provider auth shape |
| Auth-profile cooldown rotation logic (the *algorithm*) | **Model Pool** | Cross-call state, scheduler-owned |
| Tool-schema normalization (per-provider quirks) | **Providers (this page)** | The dialect rule |
| Tool-schema normalization (when to apply) | **Model Pool** | Dispatch-time decision |
| Wire codec (request shape, streaming format) | **Providers (this page)** | Provider-specific |
| Event stream normalization (uniform shape upward) | **Providers (this page)** | Provider knows where the bytes are |
| Failover policy (which model next on error) | **Model Pool** | Cross-binding decision |
| Failover signal (what *kind* of error this is) | **Providers (this page)** | Only the provider knows its error semantics |
| Cache breakpoints (where prefix ends) | **Providers (this page)** | Provider knows what its endpoint caches |
| Cache decision (whether to cache *this* call) | **Model Pool** | Routing-aware |
| Capability metadata (vision, tools, context window) | **Providers (this page)** | Per-provider/per-model fact |
| Forced-tool-choice support (`toolChoice` ladder) | **Providers (this page)** | Per-*binding* fact — same weights differ by endpoint |
| Capability query (route by capability) | **Model Pool** | Runtime selection |
| Per-call lifecycle state machine | **Model Pool** | Cross-call observability |
| Budget enforcement | **Model Pool** | Aggregate visibility |

The split holds because each row is a different temporal scope. Providers describe a *frozen contract* (auth methods, model catalog, wire codec, error taxonomy). The Pool consumes that contract at *runtime* (which provider to dispatch to, which credential to use, when to fail over). Mixing the two makes both impossible to test in isolation.

### Provider as a backend, not a surface

A provider is **never** a top-level architectural concept on the same plane as the Tool System or the Conversation Manager. It is a backend the Model Pool drives, in the same family as persistence backends (under the Conversation Manager) and execution-environment backends (under the Tool System). The naming is deliberate: `harness-template/backends/providers/` lives next to `backends/persistence/` and `backends/execution-environments/` because all three are *drivers* the inner ring uses.

The corollary: a provider plugin should never spawn its own runtime, own its own conversation state, or expose its own surface. If a "provider" needs to do those things, it's not a provider — it's a runtime (and belongs in the Sub-Agent Pool's transport adapters or as a dedicated runtime plugin).

---

## What a provider plugin owns

The unit of code on disk. The structure below is what the recommendations in [§Recommendation](#recommendation) assume; the manifest is statically validatable and inspectable without executing plugin code.

### Plugin layout on disk

```
extensions/<provider>/
  plugin.json                 # static manifest — schema-validated
  index.ts                   # plugin entry, definePluginEntry()
  provider-contract-api.ts   # auth choices + provider metadata
  models.ts                  # static catalog (or provider-catalog.ts)
  api.ts                     # wire codec — request/response/streaming
  register.runtime.ts        # runtime-time hooks (tool normalize, prompt contrib, cache)
  onboard.ts                 # OAuth / API-key onboarding flow
  cli-backend.ts             # optional — registers a CLI inference backend
  speech.ts                  # optional — registers a speech provider
  ...                        # other capability slots as needed
```



### The manifest

Static, schema-validated, no code execution at load. Keys:

```jsonc
{
  "id": "openai",
  "label": "OpenAI",
  "providerEndpoints": [
    { "id": "openai-default", "baseUrl": "https://api.openai.com/v1" }
  ],
  "providerAuthAliases": ["openai"],
  "providerAuthChoices": [
    {
      "id": "api-key",
      "label": "API Key",
      "envVars": ["OPENAI_API_KEY"],
      "cliFlag": "--openai-key",
      "cliOption": "openaiKey",
      "onboardingScopes": []
    },
    {
      "id": "oauth",
      "label": "Sign in",
      "envVars": [],
      "onboardingScopes": ["openid", "profile", "offline_access"]
    }
  ],
  "modelSupport": {
    "modelPrefixes": ["gpt-", "o1-", "o3-", "o4-"]
  },
  "cliBackends": [
    { "id": "openai-codex", "label": "Codex CLI" }
  ],
  "uiHints": {
    "iconRef": "openai-mark",
    "category": "frontier"
  }
}
```

Three properties of this shape worth being explicit about:

1. **`modelPrefixes` is what makes `provider/model-id` parsing safe.** When a user types `claude-sonnet-4-6` with no provider prefix, the registry matches it to a provider via prefix patterns rather than guessing. If two plugins claim the same prefix the loader errors at install time, not at first call.
2. **`providerAuthChoices` is open-set.** API key, OAuth, ADC (Vertex's Application Default Credentials), Bedrock IAM, GitHub Copilot SSO, Nous Portal — Auth source variety includes: API key, OAuth, ADC (Vertex), Bedrock IAM, GitHub Copilot SSO, and portal-based flows. Keep the manifest expressive enough to declare all of them.
3. **`cliBackends` is *separate* from text inference.** A provider can ship a CLI inference backend (a vendor-issued coding CLI used as an inference backend) without participating in `text-inference` provider selection. This is the capability-scope split — see [§Capability scope](#capability-scope-as-parallel-slots).

### The runtime contract

What `register.runtime.ts` exports — the methods the Pool calls.:

```ts
interface ProviderPlugin {
  // Identity
  id: string
  label: string

  // Catalog: static or dynamic
  staticCatalog?: ProviderModel[]                     // hand-curated entries
  resolveDynamicModel?(ctx: DynamicCtx): ProviderRuntimeModel | undefined
  prepareDynamicModel?(ctx: PrepareCtx): Promise<void>
  preferRuntimeResolvedModel?(ctx): boolean
  normalizeProviderModelId?(raw: string): string

  // Wire codec: the actual call
  call(model: ProviderModel, request: NormalizedRequest, signal: AbortSignal):
    AsyncIterable<NormalizedEvent>

  // Tool dialect
  normalizeToolSchemas?(tools: ToolSchema[], ctx: NormalizeCtx): ToolSchema[]

  // Prompt contributions (named-section overrides)
  resolveSystemPromptContribution?(ctx): {
    stablePrefix?: string                              // cached, above the boundary
    sectionOverrides?: Record<NamedSection, string>    // replace named slots
  }
  transformSystemPrompt?(ctx): string                  // late mutation; rarely needed

  // Cache awareness
  cacheTtlEligibility?(ctx): "none" | "short" | "long"

  // Failover signal — classification only; policy lives in the Pool
  failoverError?(err: Error): "transient" | "credential-exhausted" | "permanent"

  // Auth profile resolution
  authProfileId?(ctx): AuthProfileId

  // Per-model behavior policies
  thinkingPolicy?(ctx): ThinkingPolicy
  replayPolicy?(ctx): ReplayPolicy
  validateReplayTurns?(turns): ValidationResult
}
```

The shape is a deliberate inversion of the conventional "`AnthropicProvider extends BaseProvider` with virtual methods" layout. Provider plugins answer questions; they don't run the loop. The Pool calls into the contract; the plugin produces a piece of information or a stream chunk and returns. Stateless except for the dynamic-catalog cache (which the Pool may also own).

What is **not** on this contract, by design: scheduling, queue, budget, retry policy, model selection. Those are the Pool's job.

---

## Recommendation

### Catalog: generated, static, with dynamic overlay

Most providers ship a fixed set of models that change on a vendor cadence (months). Hand-curating catalogs at code time is the wrong primitive — it goes stale and gets fixed during prod fires. Generated catalogs are the right primitive.

A build-time script merges vendor API responses with hand-curated overrides (cost fixes, capability corrections) and emits a typed `MODELS` map keyed by `provider/modelId`. The generated map carries:

- `id`, `name`, `api` (which API kind to use), `provider`
- `cost: { input, output, cacheRead, cacheWrite }` in $/1M tokens
- `contextWindow`, `maxTokens`
- `input` array (e.g., `["text"]`, `["text", "image"]`)
- `reasoning: boolean`
- Optional `headers`, `compat` (provider-specific quirks)

`compat` is worth highlighting — use it for declarative provider quirks like `supportsEagerToolInputStreaming` and `thinkingFormat` — declarative quirks that callers query rather than detect. Keep this open-set; it's where provider-specific facts live without leaking into the call-site.

For dynamic providers (Ollama probing localhost, OpenRouter listing remote models, custom self-hosted endpoints), the plugin's `resolveDynamicModel(ctx)` returns a candidate by id; `prepareDynamicModel(ctx)` does any one-time setup. The Pool merges dynamic results into its registry view on probe. The static-catalog vs. dynamic-resolution split keeps the fast path for known models on the static path and confines network probes to the dynamic path.

### Model-ref naming: one form, parsed once

Canonical form: `provider/model-id`. Two parts. No `provider/family/model-id`. 

- If the input has no slash: default the provider from `defaultProvider`, normalize, return.
- If the input has a slash: split at the first slash, normalize provider on the left, model on the right.
- Provider normalization (`normalizeProviderId`) is alias-aware (`gpt` → `openai`, `claude` → `anthropic`).
- Model normalization (`normalizeProviderModelId`) is provider-callable; the plugin can canonicalize aliases (`opus` → `claude-opus-4-6`, `latest` → the dated id).

Two parts, not three, because the runtime is a separate dimension and goes in another field. `openrouter/anthropic/claude-sonnet-4-6` is the *displayed* form when the underlying model id is `anthropic/claude-sonnet-4-6` and the provider is `openrouter` — but the parser sees it as `provider="openrouter"`, `model="anthropic/claude-sonnet-4-6"` (everything after the first slash is the model id). This is correct: from openrouter's perspective, that whole string *is* the model id at its endpoint.

The user-facing UI string can display fancier text (e.g., `"claude-sonnet-4-6 · openrouter"`), but the engine string stays two-part.

### Auth: profiles + cooldown rotation, not env vars

Single-env-var auth is fine for "I have one OpenAI key on my laptop" and breaks the moment you have two. The right primitive is an **auth profile**: a named credential record bound to a provider, with state (last_status, last_error_reset_at, priority), and a rotation policy.

The reference shape (`PooledCredential`):

```ts
interface AuthProfile {
  id: string
  providerId: string
  authType: "api-key" | "oauth" | "iam" | "adc"
  apiKey?: string                 // for api-key
  refreshToken?: string           // for oauth
  expiresAt?: number              // for oauth
  baseUrl?: string                // override
  priority: number                // for fill_first ordering
  lastStatus: "ok" | "exhausted" | "auth-error" | "rate-limited"
  lastErrorResetAt?: number       // when to retry
  source: "env" | "config" | "oauth-store"
}
```

**Rotation strategies:** `fill_first` (priority order, default), `round_robin`, `random`, `least_used`.

**Cooldown:** when a profile is marked `exhausted` (typically 402 — "insufficient credits") or `rate-limited` (429), set `lastErrorResetAt = now + cooldown`. The Pool excludes that profile from selection until cooldown expires.

**Cooldown duration:** 1 hour for billing-class errors (a sensible default observed in practice); shorter (5–15 min) for rate-limit errors. Per-provider override is fine.

Two distinct axes worth keeping separate:

- **Auth-profile rotation** — same provider, different credential, on the *same* model. Intra-model.
- **Model fallback** — different model (possibly different provider), on the same task. Inter-model. Lives on the [Model Pool page](../../core/model-pool/#failover-policy).

Distinguish these at the type level (`auth-profiles` vs `model-fallback`) (credential pool vs. auxiliary client fallback chain). Don't collapse them.

### Wire codec: stream a request, emit normalized events

The plugin's `call(model, request, signal)` is the heart of the codec. It takes a `NormalizedRequest` (a model-agnostic envelope) and returns an `AsyncIterable<NormalizedEvent>` (a model-agnostic event stream).

The event stream is uniform across providers. The minimum event set:

```ts
type NormalizedEvent =
  | { type: "text_delta",      text: string }
  | { type: "thinking_delta",  text: string,    signature?: string }
  | { type: "toolcall_start",  id: string,      name: string,    contentIndex: number }
  | { type: "toolcall_delta",  id: string,      argumentsJson: string,    partial?: object }
  | { type: "toolcall_end",    id: string,      arguments: object }
  | { type: "usage",           input: number,   output: number,  cacheRead: number, cacheWrite: number, reasoning: number }
  | { type: "stop",            reason: "end" | "tool_use" | "max_tokens" | "stop_sequence" }
  | { type: "error",           classification: "transient" | "credential-exhausted" | "permanent", retryAfterMs?: number }
```

Two non-obvious points:

1. **Tool-call dialect is a provider concern, not a runtime concern.** Anthropic returns `{ id, name, input }`; OpenAI returns `{ id, name, arguments }`; Google returns `{ name, args }` with no id. Each adapter normalizes upward — the runtime sees `{ id, name, arguments: object }` always (synthesizing `id` if the provider didn't supply one).
2. **Thinking blocks need cross-provider replay logic.** A thinking block produced by Claude with a signature, replayed into a GPT request, needs to become text (or be dropped). Provider plugins implement this via a shared `transformMessages` step keyed on the *target* provider. This is per-provider knowledge; the runtime can't do it without provider context.

The streaming **tool-argument** dialect varies across providers and is a worth-knowing hazard:

| Provider | Streams tool args? |
|---|---|
| Anthropic (Messages API) | ✓ (eager input streaming) |
| OpenAI (Responses API) | ✗ (single chunk per tool call) |
| Google (Gemini) | ✗ |
| Bedrock | ✓ |

The plugin's `compat` block declares the capability; callers that need streaming gracefully degrade to "show toolcall_start, then toolcall_end with full args" when the provider doesn't support it.

**Forced-tool-choice support is the same kind of per-binding fact** — and a more consequential one, because getting it wrong silently breaks enforcement rather than just streaming cosmetics. `tool_choice: "required"` / `"any"` is honored by Anthropic and OpenAI's hosted endpoints but is frequently a no-op on Ollama, LM Studio, and llama.cpp servers (and varies by model and chat template even there). The binding therefore carries a [`toolChoice` ladder capability](../../core/model-pool/#the-model-registry-entry) (`"none" | "auto" | "required" | "named"`); the wire codec emits `tool_choice` only when the binding reaches the requested rung and omits it otherwise. Note this is a per-*binding* fact, not per-model: identical weights reached through Anthropic vs. a thin OpenAI-compat proxy can land on different rungs, so the model-entry baseline may be overridden downward on a specific `ProviderBinding`. The codec never tries to *guarantee* the forced call — that is the runtime's behavioral job ([agent-runtime § Forced tool choice](../../core/agent-runtime/#forced-tool-choice-stays-provider-agnostic)); the codec's only contract is "emit the wire field iff the binding honors it."

### Tool-schema normalization at the runtime seam

Some providers reject schema features other providers accept. The reference rejection list:

- OpenAI strict mode rejects `anyOf`, `oneOf`, `allOf`, type arrays.
- OpenAI strict mode requires `additionalProperties: false` on every object.
- Google rejects unknown JSON-schema keywords (`pattern`, `minLength`, etc., depending on version).

**Recommendation:** centralize the rewrite in **one place** — the runtime plan's `tools.normalize(...)` step. Tools authors write JSON-schema-2020-12 (or TypeBox); the Pool dispatches with a `provider` context; the normalization step rewrites for the target provider. Tool-author-facing advice ("prefer flat string enums over `Type.Union([Type.Literal(...)])`") is a soft guideline — the runtime makes it correct either way.

The corollary anti-pattern is *per-tool* provider-specific code. If tool definitions branch on provider, the seam is in the wrong place; lift it.

### Cache boundary and prompt contributions

Two design choices that pull in opposite directions and need to be reconciled at the provider plugin layer.

**The cache boundary.** Anthropic's prompt cache (and equivalents) only saves money if the cached prefix is *byte-identical* across calls. Provider plugins want to contribute model-family-specific prompt sections (a GPT-5 persona overlay, a Claude-style reasoning overlay) — but contributions happen at runtime, after the cache prefix is already committed. The reconciliation: a literal **boundary marker** in the system prompt (a literal `<!-- CACHE_BOUNDARY -->` comment) splits the prompt into a stable prefix (cached) and a dynamic suffix (rebuilt each turn).

Plugin contributions go in two places:

- **Stable prefix** (above the boundary): contributed at *load time*, never changes per-turn. Cached. Use for model-family persona, tool-call style, output contract.
- **Dynamic suffix** (below the boundary): contributed at *turn time*, may change. Not cached. Use for working-set-dependent context.

Plugins that try to mutate the stable prefix per-turn invalidate the cache and waste money. Make this an architectural invariant — contribution helpers enforce it.

**Named-section overrides.** Different model families want different system-prompt sections. GPT-5 wants concise output, persona-latching, parallel-lookup discipline; Sonnet wants extended thinking discipline; Haiku wants tool-discipline shorthand.:

```ts
function resolveSystemPromptContribution(ctx) {
  return {
    stablePrefix: GPT5_BEHAVIOR_CONTRACT,        // goes above the boundary
    sectionOverrides: {
      interaction_style: GPT5_INTERACTION_STYLE,
      tool_call_style:   GPT5_TOOL_CALL_STYLE,
      execution_bias:    GPT5_EXECUTION_BIAS,
    },
  }
}
```

The system prompt is structured as named sections; the plugin replaces specific sections by name. Cleaner seam than the legacy `before_prompt_build` hook (which gives the plugin the full string to mutate) because the boundary between "what's the section about" and "what does this provider say about it" stays explicit.

This is the single most often-reinvented piece of provider machinery across the harnesses, and the section-override pattern is the cleanest.

### Capability scope as parallel slots

The most consequential and most often-conflated split. **Text inference is one capability among many.** The full set of provider capabilities the harness might need:

| Capability slot | Example providers |
|---|---|
| Text inference | OpenAI, Anthropic, Google, Bedrock, Ollama, OpenRouter, ... |
| CLI inference backend | vendor-issued coding CLIs used as backends |
| Speech (STT/TTS) | OpenAI Whisper, ElevenLabs, Google Speech |
| Realtime transcription | OpenAI realtime, AssemblyAI streaming |
| Realtime voice | OpenAI realtime, ElevenLabs realtime |
| Media understanding | Gemini multimodal, Claude vision, GPT-4V |
| Image generation | OpenAI Images, Stability, Black Forest Labs |
| Video generation | Sora, Runway, Pika |
| Music generation | Suno, Udio |
| Web fetch | Built-in fetch, headless-Chromium services, Tavily |
| Web search | Tavily, Exa, Brave, SerpAPI |

These are **parallel registration slots, not flavors of one provider type.** A single vendor can ship plugins for several slots (OpenAI fills text + speech + image + realtime), but each slot has its own contract, its own plugin shape, and its own runtime hooks. The harness's text-inference selection is independent from its image-generation selection.

The split matters because **each slot has different capabilities-vs-cost-vs-latency profiles** and benefits from different selection logic. Conflating them — making "the provider" a single object that talks to all of them — leads to leaky abstractions where a "provider" has to declare what fraction of itself is text-vs-image-vs-speech.

A user-facing implication: per-agent capability resolution is an exclusive choice (one image-gen provider per agent at a time, one text provider, etc.). The plugin slots support multiple installed plugins; the agent picks one per slot.

This is the part the other five harnesses miss entirely. They handle text inference well; speech, realtime, image gen are each ad-hoc bolt-ons in `tools/`. If the harness has any ambition beyond text-out, design these slots in from the start.

### Failover: provider classifies, Pool decides

The provider knows which errors are which:

```ts
type FailoverClassification =
  | "transient"               // 5xx, timeout, disconnect — Pool retries on same binding
  | "rate-limited"            // 429 — Pool retries with backoff or rotates auth profile
  | "credential-exhausted"    // 402, "insufficient credits" — Pool rotates auth profile
  | "auth-error"              // 401, 403, expired token — Pool refreshes or fails
  | "context-overflow"        // 400 with token-overflow signature — Pool surfaces
  | "model-not-found"         // 404 with model body — Pool fails over by model
  | "policy-blocked"          // content policy refusal — Pool surfaces
  | "permanent"               // anything else — Pool surfaces
```

The error classification taxonomy should include recovery hints: `should_rotate_credential`, `should_fallback`, `should_compress`.

The provider exposes `failoverError(err)` returning a classification; the Pool decides what to do with it. The split is what makes Pool-side rotation decisions correct: the Pool sees concurrent calls' classifications across the same auth profile and decides "this profile is exhausted, mark it cooled-down for everyone." A provider couldn't make that decision because it has only per-call visibility.

### Aux-model patterns are a Pool concern, not a provider concern

Cheap-summarizer, classifier, embedder, recall-sub-agent — all of these are Pool-level routing decisions implemented via the Pool's capability query (Recommendation: [Model Pool capability query](../../core/model-pool/#capability-query-as-the-routing-surface)). They're not provider-plugin concerns.

The places `agents.defaults.compaction.model`, `agents.defaults.subagents.model`, and `active-memory.model` accept `provider/model-id` overrides is *configuration* — the user names a model; the Pool resolves it through the same provider plugins as the primary; nothing provider-specific kicks in.

A useful pattern for the Pool's "any cheap text model" fallback: an explicit auxiliary-client fallback chain (e.g., OpenRouter → custom portal → direct API-key providers). Lives on the Model Pool page; flagged here as cross-reference.

### Discovery, dynamic catalogs, and the Ollama case

For providers whose model list isn't known at code-time (Ollama on localhost, vLLM endpoints, OpenRouter's multi-vendor catalog), the plugin's `resolveDynamicModel(ctx)` does the probe and returns a candidate.

The probe should be lazy (the first call that names a previously-unseen model triggers the probe) and cached (the result lives in the Pool's registry view for the provider's TTL). For OpenRouter, the probe is a `/models` API call returning hundreds of entries; cache for hours. For Ollama, the probe is `GET /api/tags` returning local models; cache for minutes (a `pull` could add new models).

Static catalogs win for stability; dynamic catalogs win for endpoints where new models appear regularly. A provider plugin can ship both: `staticCatalog` covers the curated set, `resolveDynamicModel` covers everything else.

### Provider lifecycle: opt-in, never auto-on

*Installed* is not *active*. A provider that is present — its code linked, its manifest loaded, its catalog known — must still do **nothing** until the user explicitly opts in. This holds regardless of whether the provider shipped with the harness or was added later: a default provider and a third-party provider sit on the **same lifecycle**, and "default" affects only how prominently the provider is *surfaced*, never whether it is active.

Model the lifecycle as three states:

| State | Meaning | In the Pool? |
|---|---|---|
| **available** | Plugin code present and manifest loaded (validated, inspectable). No active credential. | **No** — excluded entirely: no catalog discovery, no registry entries, no binding candidates. |
| **registered** | The user has explicitly activated the provider — it has ≥1 active auth profile. | **Yes** — participates in catalog discovery, the registry, and dispatch. |
| **disabled** | Was registered, then explicitly deactivated. Config retained. | **No** — excluded, but its credentials/settings survive so re-enabling is one gesture. |

The activation gesture is **creating an auth profile**, and it splits cleanly by provider kind:

- **Credential-requiring providers** (hosted APIs, aggregators): registration = adding an API key or completing OAuth. No credential ⇒ no dispatch ⇒ stays *available*.
- **Local / credential-less providers** (a model server on `localhost`): registration = confirming a base-URL profile. There is no secret, but there is still an **explicit confirmation** — autodiscovery of a local port is *not* opt-in. The confirmed base-URL profile is the user's activation gesture.

Two invariants make this load-bearing:

1. **Gate at registry-build time, not dispatch time.** An *available* provider must be filtered out *before* catalog discovery runs — it contributes no model entries at all. Excluding it only at the call site (returning a "missing credential" error when something tries to dispatch) leaks ghost models into selection UIs and routing. The cheap, correct place to gate is where the registry is assembled.
2. **`default` is a UI flag, not a lifecycle input.** A manifest may declare `"default": true` so a first-run/setup surface can offer the foundational set prominently. It changes nothing about activation: a default provider with no auth profile is exactly as inert as a third-party one.

This resolves the most common provider-lifecycle bug — providers that "work" the moment they're installed because the harness auto-registers everything it can find — by making the empty-credential state a hard, registry-level exclusion rather than a soft, dispatch-time failure.

### Packaging: code plugins vs configuration plugins

A provider plugin can be distributed in two fundamentally different shapes, and a mature provider system supports both:

- **Code plugin.** Ships executable wire-codec logic — the adapter that actually talks to the endpoint. In a dynamic-plugin host this is a loadable module; in a **library/compile-time host** (a harness embedded inside another application) it is source compiled into the host by the integrator. Either way it carries code, so it carries the trust weight of code.
- **Configuration plugin.** Ships *data only* — a manifest plus an instance config that **parameterizes a generic adapter the host already ships**. No executable logic crosses the boundary. The config names a generic adapter kind (an `adapterKind` discriminator: `"openai-compat"`, `"anthropic-compat"`, …) and supplies the endpoint, auth choices, model prefixes, and an optional embedded catalog; the host binds the data to the named generic codec and produces a fully-formed, lifecycle-managed provider with its own id.

The unlock is a **generic, configurable provider as a foundational plugin.** A single OpenAI-compatible codec, shipped once as a default, covers a long tail of endpoints — local model servers, OpenAI-compatible proxies, self-hosted gateways, multi-vendor aggregators — entirely through configuration. The end user "adds a provider" by dropping in a config that points the generic codec at their endpoint; they write no code.

Three reasons this split matters:

1. **Trust boundary.** A configuration plugin can only reach what the generic adapter already exposes, so its blast radius is bounded by the adapter, not by the host's full API. Untrusted *end-user* configs are therefore safe to load where untrusted *code* would not be — the same "map content, not code" discipline the [Extensibility](../../cross-cutting/extensibility/#multi-bundle-loader-normalize-without-importing) page applies to bundles.
2. **Host-platform reality.** On hosts where loading third-party native code at runtime is constrained or forbidden — sandboxed or notarized app environments, or a harness shipped as an embedded library — the configuration path is *the* way end users extend the provider set. Code plugins are added at build time by the integrator; configuration plugins are added at runtime by the user. Drawing the line here (compile-time code extensibility + runtime configuration over generic codecs) keeps the system extensible without a dynamic-code-loading attack surface.
3. **Same lifecycle, same machinery.** A configuration plugin is *available* once loaded and *registered* once it has an auth profile (or a confirmed local base-URL), exactly like a code plugin. The loader should ingest configs from a host-designated location (the host passes the path; the plugin layer never hard-codes a filesystem location) and reject malformed data or a config whose id collides with an existing provider — as a structured error, never a crash.

This is the same factoring [Extensibility](../../cross-cutting/extensibility/#packaging-distribution-and-trust-live-in-the-registry) prescribes globally — distribution and trust are properties of *how a plugin is packaged*, not of core — specialized to the provider slot.

---

## Alternatives

### Direct SDK calls + env-driven SDK swap (single-binary CLI alternative)

This approach instantiates one SDK at startup based on env vars and uses the same query code path against whichever SDK was chosen. Model strings should be centralized with environment overrides.

**When this works:** when the harness is single-provider-per-process *and* the provider variants share an SDK family (here: four Anthropic-flavored SDKs). The four SDKs all ship near-identical `messages.create()` shapes, so the runtime stays clean.

**Why not as default:** the moment you want non-Anthropic — OpenAI, Google, anything self-hosted — the SDK-swap pattern has nowhere to go. There's no second SDK to stand up at a parallel place; the runtime has to grow a per-call dispatch path. This design works *because* a deliberately single-provider harness only has a few wire variants. Most harnesses aren't in that position. The provider-plugin shape is the generalization that handles N vendors with N codecs.

**Centralize model strings** regardless of plugin architecture. A single place where dated model ids live, with provider-aware resolution (Bedrock dynamically fetches from inference profiles; firstParty is hardcoded), is the right discipline. Don't smear `claude-sonnet-4-6` strings through call sites.

### Graph-executor framework alternative (a chat-model abstraction)

Accepts either a `"provider:model"` string or a pre-built model instance. Profile lookup is three-tier (exact-model > provider > default) and injects per-profile middleware (a prompt-caching middleware for the cache-capable provider, etc.).

**When this works:** when the harness commits to a graph-executor framework as the runtime, and is willing to inherit that framework's release cadence and abstraction debt. The middleware-first composition is genuinely good design; the profile registry is correct; tool-call dialect handling is delegated to the framework's tool-binding helper.

**Why not as default:** the model is opaque. Provider-specific concerns (custom retry policies, cache breakpoint placement, overlay semantics, capability scope beyond text) have no place to live. A compile-time model binding makes runtime swapping impractical.

The piece worth borrowing: **the three-tier profile lookup.** Match on exact model first, fall back to provider, fall back to default, and merge layered profiles when both exact and base exist. That's the right shape for any per-model tuning a provider plugin needs.

### Library-direct adapters with a transport registry

Library-direct (no third-party model-routing framework) with a `ProviderTransport` registry (`anthropic_messages`, `responses`, `chat_completions`, `bedrock_converse`) that normalizes by *api_mode* rather than by provider.

**When this works:** when the harness wants the precision of native SDKs but more than one provider speaks the same wire format. OpenAI-compat endpoints (Together, DeepInfra, Groq, ...) all use `chat_completions`; aggregators speak several modes; xAI and OpenAI both speak the `responses` mode. Transports-by-api-mode keep the codec count small even as provider count grows.

**Why not strictly as default:** the api_mode abstraction does most of what a provider plugin would do for the wire codec, but it doesn't carry manifest, capability-scope, or runtime-hook responsibilities. This kind of harness ends up with a parallel credential pool, error classifier, auxiliary client, and usage-pricing module to hold the provider-specific knowledge that a manifested plugin would centralize.

The pieces worth borrowing: the credential pool model (described in [§Auth](#auth-profiles--cooldown-rotation-not-env-vars)), the explicit error taxonomy ([§Failover](#failover-provider-classifies-pool-decides)), and the auxiliary-client fallback chain (a Model-Pool concern; cross-referenced).

### Generated catalog as static plugin

The cleanest scope: a generated `MODELS` registry, per-provider adapter files, and a stateless `stream(model, context, options)` entry. No scheduler, no failover, no cache strategy beyond per-call `cacheRetention`.

**When this works:** as the *library* the Model Pool's wire-codec layer is built on top of. A model-wire-codec library is a great abstraction for "talk to a model"; it deliberately doesn't try to be the Pool. A higher layer adds a model registry and settings manager on top to provide higher-level orchestration.

**Why this is half a provider system:** the catalog and codec are right, but the provider-plugin contract (manifest, capability scope, runtime hooks) is missing because the package isn't trying to be a plugin host. To make this a production provider system you'd add the manifest, the auth-profile primitive, and the runtime-hook contract on top.

The pieces worth borrowing: the **generated catalog** (build-time merge of vendor APIs + curated overrides), the **uniform event stream**, the **transformMessages cross-provider replay** layer, and the **`compat` declarative-quirks block**.

### Detection registry without plugin manifest

A `PROVIDERS` tuple of `ProviderSpec` records with keywords for detection, `backend_type` (`"anthropic"` / `"openai_compat"` / `"copilot"`), env vars, base URLs, and classification flags. Detection iterates the registry. Each provider has a thin client wrapper.

**When this works:** when the provider count is small enough to enumerate in a single tuple and the wire codec can be one of two or three known shapes (`anthropic_messages`, `openai_compat`).

**Why not as default:** the registry is a code edit, not a plugin install. Adding a provider requires touching multiple files. The capability scope is also flat — text only — with image-gen and speech bolted on as tools. Workable at small scale; hard to extend.

The piece worth borrowing: **the `ProviderSpec` shape itself.** Even with manifested plugins, a registry of normalized provider metadata (id, label, env vars, base urls, model prefixes, capability flags) is the right index for fast lookup and UI rendering. The plugin manifest *is* that registry, but the typed shape is identical.

---

## Anti-patterns

- **Provider as base class with model strings as parameters.** `class AnthropicProvider extends BaseProvider { call(model: string, ...) }` is the conventional shape and exactly the wrong layering. Capability metadata, cost, and context window are *per-model* not per-provider; they end up scattered into ad-hoc `if (model.startsWith("claude-haiku"))` branches at call sites. The plugin contract above inverts it: the catalog entry is the typed thing, the provider's responsibility is to know how to talk to the endpoint that hosts it. (Cross-reference: same anti-pattern listed on the [Model Pool page](../../core/model-pool/#anti-patterns).)

- **Capability scope conflated with text inference.** A "provider" object that internally branches `if (this.imageGen) ... else if (this.speech) ...` is a leaky abstraction. Each capability deserves its own slot, its own contract, its own runtime hook. The capability scope slot list should cover at minimum: text inference, speech, realtime voice, media-understanding, image-gen, video-gen, music-gen, web-fetch, and web-search.

- **Auth as a single env var per provider.** `OPENAI_API_KEY` is fine for the laptop; it fails the moment you want two keys (personal + work, prod + dev), the moment you need OAuth refresh, the moment you need cooldown rotation across multiple keys. Auth profiles + a credential pool is the right primitive. (Single-env-var fallback is fine as a *source* for an auth profile; just don't expose the env var as the abstraction.)

- **SDK swap at process startup, no per-call routing.** The `env-var-driven SDK swap` pattern works for one harness with three near-identical SDKs and breaks for everything else. The moment you want a Bedrock model and an OpenAI model in the same process, you need a per-call dispatch. Build the plugin shape; don't bet on the SDK family staying flat.

- **Per-call cache breakpoints chosen by the runtime, ignored by the provider plugin.** If the runtime decides "cache here" without consulting the provider's `cacheTtlEligibility` and the provider's stable-prefix contribution, you'll see broken cache hits and inconsistent savings. The provider knows what its endpoint caches; the runtime asks. (Counter-anti-pattern: provider plugins that *replace* the system prompt rather than contributing above the boundary marker. They invalidate the prefix on every turn. The boundary marker is what makes contribution-not-replacement enforceable.)

- **Tool-schema rewrites scattered through call sites.** `if (provider === "openai") schema = stripAnyOf(schema)` at every call site means the rule lives in N places and drifts. Centralize at the runtime seam (`runtime-plan/tools.ts:41` is the reference); plugins declare what they reject; one normalizer rewrites for the target. Tool authors stay provider-agnostic.

- **Provider-specific events leaking up.** If the runtime sees `event.type === "content_block_delta"` from one provider and `event.choices[0].delta` from another, the codec is leaking. The plugin's `call(...)` returns an `AsyncIterable<NormalizedEvent>`; everything above sees one shape. (one normalized event shape per provider)

- **Failover policy implemented inside the provider plugin.** A plugin that retries internally hides concurrent state from the Pool and breaks aggregate budget tracking. The plugin classifies errors; the Pool decides. (Inverse anti-pattern: the Pool guessing at provider error semantics. The provider knows; ask it.)

- **Compaction model picked from a different abstraction than primary models.** `agents.defaults.compaction.model: "ollama/llama3.1:8b"` should resolve through the same provider plugins, with the same auth profile machinery, as the primary. Either routing through the credential pool or accepting a plain `provider/model-id` string are both valid. The anti-pattern is a separate "summarizer client" with its own auth flow and its own model registry.

- **Manifest fields parsed at runtime via plugin code.** If the manifest's claims about `providerEndpoints` or `cliBackends` aren't statically validated, a buggy plugin breaks the harness at the worst time (first call). Validate the manifest at install time; reject malformed plugins; keep `pluginsInspect` cheap and offline.

- **Naming the runtime as part of the provider id.** `native-anthropic` or `appserver-openai` confuses the four-layer split. Provider is `anthropic`, runtime is `native`. They're orthogonal. (provider and runtime are orthogonal; keep them distinct)

- **Hand-curated catalogs as the only source.** The `MODELS` map gets stale; pricing changes; new models appear. Generated-from-vendor-API + curated-overrides is the right primitive. (generated-from-vendor-API + curated-overrides is the right primitive)

- **Auto-registering every installed provider.** Treating "the plugin is present" as "the provider is active" means a fresh install silently exposes providers the user never opted into, and an empty-credential provider leaks ghost models into selection and routing. Installed ≠ active: keep providers *available* until an explicit auth profile (or a confirmed local base-URL) promotes them to *registered*, and gate the registry build on that state.

- **Soft-gating unregistered providers at the call site.** Excluding an inactive provider only when something tries to dispatch (a "missing credential" error) is too late — its models already appeared in the registry. Filter at registry-build time so an *available*-but-not-*registered* provider contributes zero entries.

- **Code as the only packaging shape.** If the only way to add a provider is to ship executable adapter code, then end users on code-restricted hosts (sandboxed/notarized apps, embedded-library harnesses) can't extend the provider set at all, and every new OpenAI-compatible endpoint needs a new plugin. Ship a generic configurable codec as a default and let configuration plugins (data, not code) parameterize it — narrower trust boundary, runtime extensibility, no dynamic-code-loading surface.

---
