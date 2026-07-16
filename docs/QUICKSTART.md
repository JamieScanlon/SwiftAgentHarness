# Quickstart

Embed SwiftAgentHarness in a Swift app, stand up the gateway, and run a first conversation. For what each piece is, see [OVERVIEW.md](./OVERVIEW.md); for adding the package to your project, see the [README](../README.md#installation).

## 1. Add the dependencies

Link both products to your target:

```swift
.product(name: "SwiftAgentHarness", package: "SwiftAgentHarness"),
.product(name: "SwiftAgentHarnessProviders", package: "SwiftAgentHarness"),
```

## 2. Register providers and credentials

```swift
import SwiftAgentHarness
import SwiftAgentHarnessProviders

// Registers OpenAI, Anthropic, Ollama, LM Studio, and OpenRouter plugins.
SwiftAgentHarnessProviders.bootstrap()
```

Credentials come from auth profiles. `AuthProfileStore.production()` reads the process environment, so exporting `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` (or running a local Ollama with no key) is enough to start. Local OpenAI-compat endpoints can be added by dropping a `*.providerconfig.json` file into a directory and calling `ConfigPluginLoader.loadAll(from:)` — see `Sources/SwiftAgentHarnessProviders/README.md`.

## 3. Build the composition root

Resolve the host-delivered prompt configuration once, then pass that immutable snapshot to the composition root:

```swift
import Logging

let logger = Logger(label: "harness")
let configuration = HarnessConfigurationSet.resolveFromAmbient(logger: logger)

let persistence = ConversationPersistenceDomain.makeProduction(
    logger: logger, dataStoreURL: nil, allowsSwiftDataSave: true
)
let (scheduler, coordinator) = ModelCallScheduler.resolveInvocationTrackingPair(
    scheduler: nil, coordinator: nil
)
let llmFactory = StandardModelLLMFactory.productionConfigured(
    accounting: AlwaysAllowBudgetAccounting(), logger: logger
)
let transformConfig = configuration.conversationTransforms
let compactionCoordinator = CompactionConcurrencyCoordinator()

let (session, services) = HarnessRuntimeSession.makeProduction(
    persistenceDomain: persistence,
    logger: logger,
    configuration: configuration,
    conversationTransformer: ContextCompactionTransformer.makeProduction(
        config: transformConfig.contextCompaction,
        scheduling: ContextCompactionLLMScheduling(
            scheduler: scheduler,
            modelID: ContextCompactionLLMScheduling.modelID(
                model: transformConfig.contextCompaction.model,
                ollamaServerURL: transformConfig.contextCompaction.ollamaServerURL
            )
        )
    ),
    llmFactory: llmFactory,
    registryEntryProvider: nil,
    rankedRegistryEntriesProvider: nil,
    delegateCostTracker: ModelPoolCostLedger(),
    callScheduler: scheduler,
    invocationCoordinator: coordinator,
    compactionCoordinator: compactionCoordinator,
    contextEngine: DefaultContextEngine(),
    modeRegistry: ModeRegistryPortAdapter(service: ModeRegistryService.makeForHost())
)
```

## 4. Wire and start the gateway

The `APILayer` is the HTTP + WebSocket gateway every client talks through:

```swift
let ingress = SubAgentAPIIngressService(
    spawn: services.subAgentSpawnService,
    completion: services.subAgentCompletionRuntimeService
)
let runtimeGraph = SplitGatewayServiceFactory.makeRuntimeGraph(
    services: services,
    subAgentLifecycleHost: ingress,
    subAgentCompletionHost: ingress,
    subAgentCompletion: SubAgentCompletionIngressService(host: ingress)
)

let api = APILayer(port: 8080)
await api.setChatGatewayServices(SplitGatewayServiceFactory.makeGatewayServices(runtimeGraph: runtimeGraph))
await api.setModelManager(ModelManager(authProfileStore: AuthProfileStore.production()))
await api.setStartupService(services.conversationStartupService)
try await api.start()
```

## 5. Talk to it

The wire contract is specified in [`openapi/openapi.yaml`](../openapi/openapi.yaml) (REST control plane) and [`openapi/asyncapi.yaml`](../openapi/asyncapi.yaml) (WebSocket data plane).

```bash
# Health + available models
curl http://localhost:8080/status
curl http://localhost:8080/models

# Create a conversation (modelRef accepts a UUID or slug from /models)
curl -X POST http://localhost:8080/conversations \
  -H 'Content-Type: application/json' \
  -d '{"modelRef": "<model-id-or-slug>", "userSystemPrompt": "You are a helpful assistant."}'

# Send a message (starts a run; stream events over the WebSocket data plane)
curl -X POST http://localhost:8080/conversations/<id>/messages \
  -H 'Content-Type: application/json' \
  -d '{"message": "Hello!", "imageNames": []}'
```

Assistant output, tool calls, and run lifecycle events stream over the WebSocket topics described in the AsyncAPI spec.

## Shutting down

```swift
await api.stop()
await session.shutdown()
```

## Next steps

- **Tools and approvals** — tool policy is loaded from config (`ToolPolicyConfiguration`); exec approvals surface over `/exec-approvals` and `/approvals` routes.
- **MCP / A2A / ACP** — attach managers from SwiftAgentKit via `api.setMCPManager(...)` / `session.setA2AManager(...)` / `setACPManager(...)`.
- **Triggers** — cron, webhook, and channel activation via `TriggersRuntimeWiring`.
- **Design rationale** — every layer used above maps to a topic page in the [Agent Harness Best-Practice Template](../harness-template/README.md) included in this repo.
