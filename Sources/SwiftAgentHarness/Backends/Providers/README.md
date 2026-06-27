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
  manifests/                    Bundled JSON manifests (pluginsInspect parity)
  ProviderManifest.swift        Static catalog (`ProviderManifests`)
  ProviderManifestValidation.swift
  ProviderManifestLoader.swift  Bundle.module manifest loading
  ProviderCapabilitySlot.swift  11 parallel capability slots
  ProviderRegistry.swift        Plugin registry (mirrors SandboxBackendRegistry)
  ProviderPlugin.swift          TextInferenceProviding contract
  ModelRef.swift                Canonical `provider/model-id` parsing
  AuthProfile.swift             PooledCredential-shaped records
  AuthProfileStore.swift        Env + auth-profiles.json resolution
  AuthProfileCooldownState.swift
  ProviderFailoverClassification.swift
  ProviderPromptContribution.swift   CACHE_BOUNDARY marker + section overrides
  ProviderToolSchemaNormalization.swift
  ProviderRuntimeHooks.swift    Pool dispatch seam (tools, prompt, failover)
  TextInference/                Built-in text inference plugins
  Slots/                        Non-text capability slot protocols (scaffold)
```

## Built-in text-inference plugins

| Provider ID | Adapter | Discovery |
|---|---|---|
| `openai` | `OpenAILLM` | Static catalog (future) |
| `anthropic` | `AnthropicLLM` | Static catalog (future) |
| `ollama` | `OllamaLLM` | Dynamic probe + `Constants.ollamaModelIDMap` overrides |
| `lmstudio` | `LMStudioLLM` | Dynamic probe + `Constants.lmStudioModelIDMap` overrides |
| `openrouter` | `OpenAILLM` (OpenAI-compat) | Dynamic model scaffold |

## Integration points

- **`StandardModelLLMFactory.makeBindingAdapter`** delegates adapter construction to `ProviderRegistry`.
- **`ModelManager.syncRegistryFromDiscovery`** merges entries from all registered text-inference plugins.
- **`BindingFailoverClassifier`** consults provider `failoverError` before generic classification.
- **`TurnLoop`** normalizes tools via `ProviderRuntimeHooks.normalizeTools`.
- **`OrchestratorRuntimeService.orchestratorAdditionalParameters`** merges provider section overrides.

## Capability slots (scaffold)

Text inference is one slot among eleven: `text-inference`, `cli-inference-backend`, `speech`, `realtime-transcription`, `realtime-voice`, `media-understanding`, `image-generation`, `video-generation`, `music-generation`, `web-fetch`, `web-search`. Non-text slots have protocol stubs in `Slots/`; wire codecs land when SwiftAgentKit exposes the corresponding surfaces.

## Tests

`Tests/SwiftAgentHarnessTests/Backends/Providers/` — manifest validation, model-ref parsing, auth profiles, failover taxonomy, registry bootstrap, runtime hooks.
