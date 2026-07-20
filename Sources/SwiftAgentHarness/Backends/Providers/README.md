# Providers Backend

Wire-codec backend plugins for external inference endpoints. Implements the harness-template [`backends/providers`](../../../../../../Documents/Claude/Projects/Agentic%20Harness%20Research/harness-template/backends/providers/README.md) spec.

Providers are **not** the unit of model selection — the [Model Pool](../../Core/ModelPool/README.md) is. Providers supply manifests, auth shape, wire codecs, tool dialect, cache boundaries, and error taxonomy. The Pool owns rotation policy, failover decisions, budget, and scheduling.

## Plugin model

Two plugin flavors:

1. **Code plugins** — compiled `ProviderRegistration` values (built-in set in `SwiftAgentHarnessProviders`, or third-party source compiled into the app). No runtime native loading.
2. **Configuration plugins** — `*.providerconfig.json` files that parameterize a generic adapter (`adapterKind`, e.g. `openai-compat`) already shipped in the app.

### Two registrations (do not conflate)

| Term | Meaning |
|---|---|
| **Plugin registration** | Provider enters `ProviderRegistry` via `registerDefaults()` or `ConfigPluginLoader` → provider is **available** |
| **Provider registration** (user opt-in) | User creates ≥1 active `AuthProfile` (or a `local` profile for credential-less providers) → provider is **registered** and participates in the Pool |

Unregistered providers contribute nothing to discovery. `ModelManager` gates `syncRegistryFromDiscovery()` on `ProviderRegistry.registeredTextInferenceProviders(authStore:)`.

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
Backends/Providers/             Plugin SDK (contracts + machinery)
  ProviderRegistry.swift        Plugin registry + bootstrap hook
  ProviderLifecycle.swift       available / registered / disabled
  ProviderAdapterFactory.swift  Config-plugin factory registry
  ProviderInstanceConfig.swift  Configuration-plugin schema + loader
  ProviderLLMBridge.swift       Core wire-codec construction for plugins
  ProviderResourceBundle.swift  Resource bundle pointer for JSON catalogs
  …

SwiftAgentHarnessProviders/     Foundational code plugins (separate target)
  registerDefaults.swift        App entry point
  manifests/*.manifest.json     Canonical provider metadata
  catalogs/*.catalog.json       Bundled static model catalogs
```

JSON manifests under `SwiftAgentHarnessProviders/manifests/` are the **single source of truth** for bundled provider metadata. `ProviderManifestValidationTests` guards decode round-trip stability.

## Built-in text-inference plugins

Link `SwiftAgentHarnessProviders` and call `registerDefaults()`. Built-in plugins:

| Provider ID | Adapter | Discovery |
|---|---|---|
| `openai` | `OpenAILLM` | Bundled static catalog (`catalogs/openai.catalog.json`) |
| `anthropic` | `AnthropicLLM` | Bundled static catalog (`catalogs/anthropic.catalog.json`) |
| *(host-configured)* | selected by `adapterKind` (e.g. `ollama`, `lmstudio`) | Dynamic probe + host `InferenceRuntimeConfig.modelIDMap` overlays |
| `openrouter` | `OpenAILLM` (OpenAI-compat) | Bundled seed + `GET /models` dynamic overlay |

API-server providers are not auto-registered. Pass `DefaultProviderOptions.inferenceRuntimes` (0…N `InferenceRuntimeConfig` values) to `bootstrap` / `registerDefaults`. Host-chosen `providerID` need not match `adapterKind`.

## Integration points

- **`StandardModelLLMFactory.makeBindingAdapter`** delegates adapter construction to `ProviderRegistry`.
- **`ModelManager.syncRegistryFromDiscovery`** merges entries from registered (opt-in) text-inference plugins only.
- **`BindingFailoverClassifier`** consults provider `failoverError` before generic classification.
- **`TurnLoop`** normalizes tools via `ProviderRuntimeHooks.normalizeToolSchemaBatch` (canonical schema from `ToolRegistryEntry.canonicalParametersSchema` + provider compat profile) and passes `toolParameterSchemasByName` / `toolSchemaStrictByName` through `LLMRequestConfig`.
- **`OrchestratorRuntimeService.orchestratorInvocationOptions`** fills the same schema maps for orchestrator `updateConversation` paths.
- **`ProviderAdapterContext.compat`** carries per-model streaming dialect (`supportsEagerToolInputStreaming`, `thinkingFormat`). Adapters project the full **normalized event set** through `NormalizedStreamEmitter`; eager vs buffered tool-argument streaming follows `compat.supportsEagerToolInputStreaming`.
- **`transformMessages` / `replayPolicy` / `validateReplayTurns`** on `TextInferenceProviding` reshape assistant turns for the target provider before dispatch (cross-provider thinking-block replay). `ProviderRuntimeHooks` delegates from TurnLoop after `RenderableMessageInvariant.sanitizeForDispatch`.
- **`prepareDynamicModel` / `preferRuntimeResolvedModel`** support lazy dynamic catalog resolution in `ModelManager.resolve(.slug)` (OpenRouter prefers runtime `/models` overlay; Ollama defers `modelInfo` to prepare).
- **`OrchestratorRuntimeService.orchestratorAdditionalParameters`** merges provider section overrides.

## Auth profiles (open-set)

Manifest `providerAuthChoices` supports API key, OAuth, IAM, ADC, and **local** (base-URL-only confirmation for credential-less providers) via optional `authType`.

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
