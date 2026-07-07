# Model Pool

The Model Pool is the harness chokepoint for model dispatch, budget enforcement, failover, and pool-derived UI signals.

## Budget enforcement

`BudgetEnforcingLLM` wraps every factory-built adapter. Production uses `ModelPoolCostLedger` with `BudgetPolicy` loaded from `PromptConfig.json` (`settings.modelPoolBudget`) and optional `ServerConfig` / env overrides. `ModelPoolRuntimeWiring.resolve()` and the server composition root both wire the same ledger into `StandardModelLLMFactory.productionConfigured(...)`.

Safe defaults (`ModelPoolBudgetConfiguration.safeDefaults`, enabled):

- `maxUSDPerCall`: 1.00
- `maxUSDPerConversation`: 10.00
- `maxUSDGlobal`: 100.00
- `denyWhenUnknownProjectedCost` → `projectedCostFallback`: deny when unknown

Disable at runtime with `SAH_MODEL_POOL_BUDGET_DISABLED=1`.

Per-conversation `ConversationBudgetSnapshot.maxUSD` is enforced as a tighter cap when present (hydrated at startup and updated on spend snapshot persistence).

## Thinking config vs thinking signal

**Request config (modes-owned):** `ThinkingConfigResolver` in ConversationManager resolves mode profile + conversation routing prefs into a `ThinkingConfig`, passed through orchestrator `additionalParameters` to adapters (`OpenAILLM`, `OllamaLLM`, `LMStudioLLM`, `AnthropicLLM`).

**UI signal (pool-owned):** `ModelInvocationCoordinator` + `ModelStateDeriver` derive `ModelStatePayload.thinking` from:

1. Connecting phase > 200ms (`ModelStateDeriver.connectingThinkingThresholdSeconds`)
2. Structured `.reasoning` stream fragments (OpenAI / Anthropic normalized path)
3. Inline `think` / `redacted_thinking` XML-style tags when visible assistant text is empty but tagged reasoning body is present (local models)

This differs from the harness template, which places thinking resolution in the Pool. This implementation keeps resolution in modes because inputs are mode-owned; the Pool translates resolved config to provider wire formats and derives the UI signal from invocation/stream state.

## Provider adapters

| `ModelProtocol` | Adapter |
|-----------------|---------|
| `ollama` | `OllamaLLM` |
| `openAIAPI` | `OpenAILLM` |
| `lmStudio` | `LMStudioLLM` |
| `anthropic` | `AnthropicLLM` |

`MultiBindingFailoverLLM` rotates across ordered `ProviderBinding` rows when the registry supplies multiple bindings. Discovery merges single-binding provider rows that share a `canonicalModelKey` into one logical entry (see below).

Cross-provider binding merge:

- Each catalog row (and local `Constants` model map entry) may declare `canonicalModelKey` (logical identity: family + version) and `modelFamily` (coarse family for ranking).
- `ModelManager.syncRegistryFromDiscovery` groups rows by that key and unions bindings sorted by configured provider preference (`settings.modelPoolProviderPreference.order`).
- Unknown OpenRouter runtime rows may derive a key from `vendor/model` only when the tail exactly matches an existing explicit key (audited in logs).
- Per-binding fields (`cost`, `routing`, `serverURL`, `authProfile`, `toolChoiceModesOverride`) are preserved on each binding; model-level metadata comes from the highest-preference source.

**Breaking change:** per-provider registry UUIDs for models merged under a first-party UUID (for example OpenRouter Sonnet `c300…0001` merged into Anthropic `b200…0002`) are no longer published as separate registry rows.

Cross-provider failover coverage:

- `MultiBindingFailoverLLMTests` — binding classifier, auth-probe skip, stream pre-first-chunk rules, and anthropic→openAI failover with stub adapters.
- `StandardModelLLMFactoryAdapterTests` — factory adapter dispatch for all four `ModelProtocol` values and factory-wrapped heterogeneous failover wiring.

Same-binding retries use `FailoverPolicy` from `settings.modelPoolFailover` (default: 2 retries, 0.25s base delay, 5s max delay).

Bedrock and Vertex native adapters remain deferred (no `ModelProtocol` cases or wire implementations yet). Anthropic is the first cloud-native adapter in this slice; OpenAI-shaped endpoints cover many hosted proxies until Bedrock/Vertex land.

## Key types (this folder)

| Type | Role |
|------|------|
| [`StandardModelLLMFactory`](StandardModelLLMFactory.swift) | Provider adapter dispatch, budget/failover/cache wrapping |
| [`ModelPoolRuntimeWiring`](ModelPoolRuntimeWiring.swift) | Shared ledger + factory resolution for session and composition root |
| [`ModelInvocationCoordinator`](ModelInvocationCoordinator.swift) | Per-model lifecycle, thinking derivation, `ModelStatePayload` publish |
| [`ModelCallScheduler`](ModelCallScheduler.swift) | Admission / queue policy for model calls |
| [`MultiBindingFailoverLLM`](MultiBindingFailoverLLM.swift) | Cross-binding rotation and preflight |
| [`BudgetEnforcingLLM`](BudgetEnforcingLLM.swift) | Per-call budget gate around adapters |

## Related modules

- **Conversation Manager:** [`../ConversationManager/InteractionModes/ThinkingConfigResolver.swift`](../ConversationManager/InteractionModes/ThinkingConfigResolver.swift) — mode-owned thinking config resolution
- **Communication Layer:** [`../CommunicationLayer/ModelPoolResourceTopicPublishing.swift`](../CommunicationLayer/ModelPoolResourceTopicPublishing.swift) — `pool/health`, `models/registry`, `model/{id}/state` fan-out
- **Agent Runtime:** [`../AgentRuntime/README.md`](../AgentRuntime/README.md) — turn loop invokes pool-scheduled model calls
