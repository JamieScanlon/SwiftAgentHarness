# Providers Backend

Wire-codec backend plugins for external inference endpoints. Implements the harness-template [`backends/providers`](../../../../../../Documents/Claude/Projects/Agentic%20Harness%20Research/harness-template/backends/providers/README.md) spec.

Providers are **not** the unit of model selection — the [Model Pool](../../Core/ModelPool/README.md) is. Providers supply manifests, auth shape, wire codecs, tool dialect, cache boundaries, and error taxonomy. The Pool owns rotation policy, failover decisions, budget, and scheduling.

## Layer split

| Concern | Owner |
|---|---|
| Plugin manifest, registration, static catalog | **Providers (this folder)** |
| Auth profile records + env/file resolution | **Providers** |
| Cooldown rotation algorithm | **Model Pool** |
| Wire codec (`makeAdapter`) | **Providers** |
| Failover signal (`failoverError`) | **Providers** |
| Failover policy (retry, rotate, substitute) | **Model Pool** |
| Tool-schema normalization rules | **Providers** (`ProviderToolSchemaNormalizer`) |
| When to normalize tools | **Model Pool / Agent Runtime** (`ProviderRuntimeHooks`) |
| Model-ref parse (`provider/model-id`) | **Providers** (`ModelRefParser`) |

## Layout

```
Backends/Providers/
Bundled JSON under `manifests/` mirrors `ProviderManifests` for pluginsInspect-style offline inspection. Runtime bootstrap uses the Swift literals; `ProviderManifestValidationTests` asserts full parity so the two sources cannot drift silently (Ollama/LM Studio endpoint URLs normalize to bundled localhost forms).
  catalogs/                     Bundled static model catalogs + overrides
  ProviderManifest.swift        Static catalog (`ProviderManifests`)
  ProviderManifestValidation.swift
  ProviderManifestLoader.swift  Bundle.module manifest loading
  ProviderCapabilitySlot.swift  11 parallel capability slots
  ProviderRegistry.swift        Plugin registry (mirrors SandboxBackendRegistry)
  ProviderPlugin.swift          TextInferenceProviding contract
  ModelRef.swift                Canonical `provider/model-id` parsing
  AuthProfile.swift             PooledCredential-shaped records
  AuthProfileStore.swift        Env + auth-profiles.json + oauth-store resolution
  ProviderOAuthTokenRefreshing.swift OAuth refresh seam (stub)
  ProviderAuthOnboarding.swift  Provider onboarding seam (stub)
  ProviderAuthChoice+AuthType.swift Auth choice typing + inference
  AuthProfileCooldownState.swift
  ProviderFailoverClassification.swift
  ProviderPromptContribution.swift   CACHE_BOUNDARY marker + section overrides
  ProviderToolSchemaNormalization.swift
  ProviderRuntimeHooks.swift    Pool dispatch seam (tools, prompt, failover)
  ProviderSlotRuntimeHooks.swift Non-text slot dispatch seam (registration only today)
  TextInference/                Built-in text inference plugins
  Slots/                        Non-text capability slot protocols (scaffold)
```

## Built-in text-inference plugins

| Provider ID | Adapter | Discovery |
|---|---|---|
| `openai` | `OpenAILLM` | Bundled static catalog (`catalogs/openai.catalog.json`) |
| `anthropic` | `AnthropicLLM` | Bundled static catalog (`catalogs/anthropic.catalog.json`) |
| `ollama` | `OllamaLLM` | Dynamic probe + `Constants.ollamaModelIDMap` overrides |
| `lmstudio` | `LMStudioLLM` | Dynamic probe + `Constants.lmStudioModelIDMap` overrides |
| `openrouter` | `OpenAILLM` (OpenAI-compat) | Bundled seed + `GET /models` dynamic overlay |

## Integration points

- **`StandardModelLLMFactory.makeBindingAdapter`** delegates adapter construction to `ProviderRegistry`.
- **`ModelManager.syncRegistryFromDiscovery`** merges entries from all registered text-inference plugins.
- **`BindingFailoverClassifier`** consults provider `failoverError` before generic classification.
- **`TurnLoop`** normalizes tools via `ProviderRuntimeHooks.normalizeTools`.
- **`ProviderAdapterContext.compat`** carries per-model streaming dialect (`supportsEagerToolInputStreaming`, `thinkingFormat`). Adapters project the full **normalized event set** through `NormalizedStreamEmitter`; eager vs buffered tool-argument streaming follows `compat.supportsEagerToolInputStreaming`.
- **`transformMessages` / `replayPolicy` / `validateReplayTurns`** on `TextInferenceProviding` reshape assistant turns for the target provider before dispatch (cross-provider thinking-block replay). `ProviderRuntimeHooks` delegates from TurnLoop after `RenderableMessageInvariant.sanitizeForDispatch`.
- **`prepareDynamicModel` / `preferRuntimeResolvedModel`** support lazy dynamic catalog resolution in `ModelManager.resolve(.slug)` (OpenRouter prefers runtime `/models` overlay; Ollama defers `modelInfo` to prepare).
- **`OrchestratorRuntimeService.orchestratorAdditionalParameters`** merges provider section overrides.

## Auth profiles (open-set)

Manifest `providerAuthChoices` supports API key, OAuth, IAM, and ADC via optional `authType` (inferred from choice `id` when omitted). Validation requires `envVars` only for `.apiKey` choices — OAuth choices may use `envVars: []` with `onboardingScopes`.

- **`AuthProfileStore.resolveCredentialPool`** merges env keys, config file entries, and oauth-store records (`accessToken`/`refreshToken`/`expiresAt`).
- **`AuthProfileStore.resolveCredential`** returns a dispatch-ready bearer token or throws `credentialRequiresOnboarding` / `credentialExpired`.
- **`resolveAPIKey`** delegates to `resolveCredential` (backward-compatible `apiKey` alias on `ResolvedAuthCredential`).
- **`StandardModelLLMFactory.makeBindingAdapter`** returns `MissingAuthCredentialLLM` when wire credentials are required but not dispatch-ready (no silent empty token).
- **`ProviderOAuthTokenRefreshing`** / **`ProviderAuthOnboarding`** are protocol stubs for refresh and onboarding; wire to [`OAuthCallbackDelivery`](../../Core/CommunicationLayer/OAuth/OAuthCallbackDelivery.swift) in a future slice.

**Deferred**: full OAuth PKCE flow, IAM/ADC SDK providers, token persistence write-back, WS onboarding endpoints.

## Capability slots

Text inference is one slot among eleven: `text-inference`, `cli-inference-backend`, `speech`, `realtime-transcription`, `realtime-voice`, `media-understanding`, `image-generation`, `video-generation`, `music-generation`, `web-fetch`, `web-search`.

**Registration plumbing** (implemented): `ProviderRegistration` holds optional implementations per slot; `ProviderRegistry` indexes CLI backends separately (`providerID/cliBackendID`) and exposes `provider(for:providerID:)`, `cliInferenceBackend(providerID:cliBackendID:)`, and `inspectSlots()`. Built-in OpenAI/Anthropic bootstrap registers stub slot providers matching manifest declarations (e.g. OpenAI `openai-codex` CLI backend, speech/image/realtime-voice stubs; Anthropic media-understanding stub). `ProviderSlotRuntimeHooks` is the future dispatch facade.

**Still deferred**: non-text wire codecs, agent-runtime dispatch to slot providers (image generation still flows through text-inference `LLMProtocol.generateImage`), CLI backend process spawn, and WS `pluginsInspect` slot-matrix exposure.

## Tests

`Tests/SwiftAgentHarnessTests/Backends/Providers/` — manifest validation, model-ref parsing, auth profiles, failover taxonomy, registry bootstrap, runtime hooks.
