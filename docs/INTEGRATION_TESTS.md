# Integration Test Inventory

Catalog of integration-style tests in `SwiftAgentHarnessTests` and proposed unit-test replacements.
Tests are classified by tier:

| Tier | Pattern | Action |
|------|---------|--------|
| **A** | Live TCP / WebSocket / NIO HTTP / `URLSession` loopback | Replace entirely |
| **B** | Vapor in-process HTTP (`VaporTesting.withApp`) | Replace with route-handler unit tests |
| **C** | Real subprocess / sandbox / filesystem | Decompose; keep minimal smoke |
| **D** | Multi-component flows (no external I/O) | Decompose into service-level unit tests |

## Tier A — Live Network I/O

| File | Suite | Tests | Hang risk | Why integration | Proposed unit replacement | Existing coverage | Action |
|------|-------|-------|-----------|-------------------|---------------------------|-------------------|--------|
| [APILayerWebSocketCoverageTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APILayerWebSocketCoverageTests.swift) | `APILayerWebSocketCoverageTests` | 49 | `.serialized`, 2-min limits, flake comments | `APILayer.start()` + `URLSessionWebSocketTask` | `*TopicHubTests`, `WebSocketTopicSubscriptionRouterTests`, `APILayerWebSocketMigrationErrorTests`, `WebSocketOutboundWireEncodingTests` | Partial hub/router coverage | **Replace** |
| [APILayerGatewaySplitServicesNetworkTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APILayerGatewaySplitServicesNetworkTests.swift) | `APILayerGatewaySplitServicesNetworkTests` | 3 | — | `api.start()` + `URLSession` GET | `APILayerGatewaySplitServicesTests`, `APILayerStatusRouteTests`, `APILayerTracesRouteTests` | Gateway wiring unit tests exist | **Replace** |
| [APILayerStreamingCoverageTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APILayerStreamingCoverageTests.swift) (smoke only) | `APILayerStreamingCoverageTests` | 2 live | `.serialized` | `api.start()` + `URLSession` REST/WS | `APILayerStreamingRouteHandlerTests`, `WebSocketCommClientControlValidatorTests` | Vapor route tests in same file | **Replace smoke** |
| [SessionBlobPinnedHTTPClientTests.swift](../Tests/SwiftAgentHarnessTests/Backends/Persistence/SessionBlobPinnedHTTPClientTests.swift) | `SessionBlobPinnedHTTPClientTests` | 2 | — | NIO `ServerBootstrap` on loopback | `SessionBlobHTTPTransportDecodingTests` with stub transport | — | **Replace** |
| [OpenAILLMStreamContractNetworkTests.swift](../Tests/SwiftAgentHarnessTests/Common/OpenAILLMStreamContractNetworkTests.swift) | `OpenAILLMStreamContractNetworkTests` | 2 | — | TCP to `127.0.0.1:1` | `OpenAILLMStreamContractTests` with injected stream seam | Partial contract tests | **Replace** |
| [APIAccessTokenAuthenticationTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APIAccessTokenAuthenticationTests.swift) (`startFailsClosedWithoutValidator`) | `APIAccessTokenAuthenticationTests` | 1 | — | Calls `api.start()` (throws before bind) | `APILayerStartupValidationTests` | Other auth tests are unit | **Replace** |

## Tier B — Vapor In-Process HTTP

| File | Suite | Tests | Hang risk | Why integration | Proposed unit replacement | Action |
|------|-------|-------|-----------|-------------------|---------------------------|--------|
| [APILayerRESTCoverageTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APILayerRESTCoverageTests.swift) | `APILayerRESTCoverageTests` | 100 | `.serialized` | Full HTTP via `withApp` | Split into `APILayerStatusRouteTests`, `APILayerModelsRouteTests`, `APILayerConversationsRouteTests`, `APILayerConversationsListRouteTests`, `APILayerConversationProjectionRouteTests`, `APILayerRunsRouteTests`, `APILayerSubAgentsRouteTests`, `APILayerTenancyRouteTests` | **Replace** |
| [APILayerStreamingCoverageTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APILayerStreamingCoverageTests.swift) | `APILayerStreamingCoverageTests` | 18 Vapor | `.serialized` | SSE/stream routes via `withApp` | `APILayerStreamingRouteHandlerTests` | **Replace** |
| [APILayerManualCompactRestTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APILayerManualCompactRestTests.swift) | `APILayerManualCompactRestTests` | 7 | `.serialized` | Compact REST + runtime | Route handler + `ContextCompactionInputBuilderTests` | **Replace** |
| [APILayerModelRefRoutingTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APILayerModelRefRoutingTests.swift) | `APILayerModelRefRoutingTests` | 5 | `.serialized` | Model ref through HTTP | `APILayerConversationAdapterTests` | **Replace** |
| [APILayerImageLoaderTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/API/APILayerImageLoaderTests.swift) | — | 1 | — | Image loader REST | Route handler unit test | **Replace** |
| [ConversationSearchTests.swift](../Tests/SwiftAgentHarnessTests/Core/ConversationManager/ConversationSearchTests.swift) | `GET /api/search` | 3 `withApp` | `.serialized` | Search REST | SQLite catalog + query builder unit tests | **Replace Vapor portion** |
| [OAuthTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/OAuth/OAuthTests.swift) | OAuth callback | 4 Vapor | — | `GET /oauth/callback` | `OAuthCallbackReceiver` unit tests + route handler | **Replace Vapor portion** |
| [RunLifecycleDurabilityTests.swift](../Tests/SwiftAgentHarnessTests/Backends/Persistence/RunLifecycleDurabilityTests.swift) | `RunLifecycleDurabilityTests` | 2 Vapor | `.serialized` | REST `/runs` | `APILayerRunsRouteTests` | **Replace Vapor portion** |

## Tier C — Subprocess / Sandbox

| File | Suite | Tests | Hang risk | Why integration | Proposed unit replacement | Action |
|------|-------|-------|-----------|-------------------|---------------------------|--------|
| [ShellProcessRunnerSupervisedTests.swift](../Tests/SwiftAgentHarnessTests/Backends/ExecutionEnvironments/ShellProcessRunnerSupervisedTests.swift) | — | 8 | `.serialized` | Real `/bin/bash` | Mock process launch + drain algorithm tests | **Decompose; 1–2 smoke** |
| [ShellProcessRunnerDrainTests.swift](../Tests/SwiftAgentHarnessTests/Backends/ExecutionEnvironments/ShellProcessRunnerDrainTests.swift) | — | 5 | — | Pipe draining | `ShellProcessRunnerDrainUnitTests` | **Decompose** |
| [BackgroundProcessSessionScopeTests.swift](../Tests/SwiftAgentHarnessTests/Backends/ExecutionEnvironments/BackgroundProcessSessionScopeTests.swift) | — | 2 | `.serialized` | Live bash + registry | `BashProcessRegistry` in-memory tests | **Decompose; smoke** |
| [LocalSandboxBackendTests.swift](../Tests/SwiftAgentHarnessTests/Backends/ExecutionEnvironments/LocalSandboxBackendTests.swift) | — | ~6 | — | Seatbelt + real shell | Seatbelt argv/profile unit tests | **Decompose; 1 smoke** |
| [WorkspaceFilesystemToolProviderTests.swift](../Tests/SwiftAgentHarnessTests/Core/ToolSystem/WorkspaceFilesystemToolProviderTests.swift) | — | 45 | `.serialized`, 1-min limit | Real FS + sandboxed bash | `WorkspaceFilesystemToolArgumentParsingTests`, `WorkspaceFilesystemToolApprovalEscalationTests`, `WorkspaceGrepRunnerUnitTests` | **Decompose; 2–3 smoke** |
| [WorkspaceGrepRunnerTests.swift](../Tests/SwiftAgentHarnessTests/Core/ToolSystem/WorkspaceGrepRunnerTests.swift) | — | 2 | — | Sandbox grep pipeline | Extend unit grep tests | **Partial decompose** |
| [BackgroundSupervisionTests.swift](../Tests/SwiftAgentHarnessTests/Core/AgentRuntime/BackgroundSupervisionTests.swift) | — | 16 | `.serialized` | Real bash processes | Registry/budget/argv unit tests | **Decompose; 1 smoke** |
| [ExecutionEnvironmentsTests.swift](../Tests/SwiftAgentHarnessTests/Backends/ExecutionEnvironments/ExecutionEnvironmentsTests.swift) | — | 2 | — | Temp dirs + `ExecRuntimeService` | Mirror routing unit tests | **Partial decompose** |

## Tier D — Multi-Component Flows

| File | Suite | Tests | Hang risk | Why integration | Proposed unit replacement | Action |
|------|-------|-------|-----------|-------------------|---------------------------|--------|
| [AgentRuntimeSection6ComplianceTests.swift](../Tests/SwiftAgentHarnessTests/Core/AgentRuntime/AgentRuntimeSection6ComplianceTests.swift) | — | 12 | `.serialized` | Full agent runtime flows | `AgentRuntimeToolRoundTripTests`, `AgentRuntimeDualConversationIsolationTests`, `AgentRuntimeCancelPartialTests`, `AgentRuntimeApprovalLifecycleTests` | **Decompose** |
| [ControlInputBoundaryIntegrationTests.swift](../Tests/SwiftAgentHarnessTests/Surfaces/Interface/Commands/ControlInput/ControlInputBoundaryIntegrationTests.swift) | — | 3 | `.serialized` | Full `HarnessRuntimeSession` | `SlashCommandDispatchService` unit tests | **Decompose** |
| [ConversationCatalogVisibilityIntegrationTests.swift](../Tests/SwiftAgentHarnessTests/Core/ConversationManager/ConversationCatalogVisibilityIntegrationTests.swift) | — | 6 | — | Runtime + catalog filters | `ConversationScope` unit tests | **Decompose** |
| [HarnessRuntimeSessionTurnProcessorIntegrationTests.swift](../Tests/SwiftAgentHarnessTests/Core/ConversationManager/HarnessRuntimeSessionTurnProcessorIntegrationTests.swift) | — | 1 | — | On-disk harness + backfill | `TurnProcessor` unit tests | **Decompose** |
| [HarnessRuntimeSessionSlashCommandDispatchTests.swift](../Tests/SwiftAgentHarnessTests/Core/ConversationManager/HarnessRuntimeSessionSlashCommandDispatchTests.swift) | — | — | `.serialized` | Slash + runtime | `SlashCommandDispatchService` | **Decompose** |
| [HarnessRuntimeSession*Tests](../Tests/SwiftAgentHarnessTests/Core/ConversationManager/) (~25 files) | Various | ~80 | Many `.serialized` | Full runtime wiring | Service-level tests per file in plan | **Decompose** |
| [SlashCommandSystemEdgeCaseTests.swift](../Tests/SwiftAgentHarnessTests/Core/ConversationManager/SlashCommandSystemEdgeCaseTests.swift) (integration section) | `HarnessRuntimeSessionSlashEdgeCaseIntegrationTests` | 5 | `.serialized` | Slash queue drain | Slash queue service unit tests | **Decompose** |
| [ConversationsToolProviderTests.swift](../Tests/SwiftAgentHarnessTests/Core/ToolSystem/ConversationsToolProviderTests.swift) (runtime section) | — | 4 | `.serialized` | Tool → runtime E2E | Stub `ConversationToolDataService` | **Decompose** |
| [ContextCompactionToolPairE2ETests.swift](../Tests/SwiftAgentHarnessTests/Core/ContextEngine/Compaction/ContextCompactionToolPairE2ETests.swift) | — | 3 | — | Full compaction pipeline | `ContextCompactionInputBuilderTests`, alignment tests | **Replace** |
| [CheckpointProductionSuiteTests.swift](../Tests/SwiftAgentHarnessTests/Core/ContextEngine/Compaction/CheckpointProductionSuiteTests.swift) | — | 2 | `.serialized` | Runtime checkpoints | Checkpoint emission unit tests | **Replace** |
| [CommunicationLayerEnrichmentSmokeTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/CommunicationLayerEnrichmentSmokeTests.swift) | — | 14 | — | Enrichment pipeline | `CapabilityRegistryTopicHub` unit tests | **Decompose** |
| [APIProjectionParityTests.swift](../Tests/SwiftAgentHarnessTests/Core/CommunicationLayer/APIProjectionParityTests.swift) | — | 5 | `.serialized` | Full session → API parity | `SplitConversationAdapter` tests | **Decompose** |
| [CommunicationLayerConversationStreamSourceTests.swift](../Tests/SwiftAgentHarnessTests/Surfaces/Interface/Streaming/CommunicationLayerConversationStreamSourceTests.swift) | — | 1 (`endToEndFromHub`) | `.serialized` | Hub → stream source | Hub + stream source unit tests | **Decompose** |
| [TriggersIntegrationTests.swift](../Tests/SwiftAgentHarnessTests/Surfaces/Triggers/TriggersIntegrationTests.swift) | — | 2 | — | Scheduler → dispatch | `TriggerSchedulerService` + stub capture | **Decompose** |
| [TriggerWorkflowIntegrationTests.swift](../Tests/SwiftAgentHarnessTests/Surfaces/Triggers/TriggerWorkflowIntegrationTests.swift) | — | 1 | — | Webhook chain | `TriggerDispatchService` unit tests | **Decompose** |
| [FileEventQueueIntegrationTests.swift](../Tests/SwiftAgentHarnessTests/Surfaces/Triggers/FileEvent/FileEventQueueIntegrationTests.swift) | — | 2 | — | File watcher queue | `FileEventQueueService` injected events | **Decompose** |
| [MockChannelListenerIntegrationTests.swift](../Tests/SwiftAgentHarnessTests/Surfaces/Triggers/Channel/MockChannelListenerIntegrationTests.swift) | — | 2 | — | Channel listener round-trip | Mock plugin unit tests | **Decompose** |
| [RuntimeTests.swift](../Tests/SwiftAgentHarnessTests/Surfaces/Interface/TUI/RuntimeTests.swift) | `TUIAppIntegrationTests` | 3 | — | Full TUI ingest/render | `TUIApp` + stub stream source | **Decompose** |
| [AdapterContractOrchestratorSmokeTests.swift](../Tests/SwiftAgentHarnessTests/Common/AdapterContractOrchestratorSmokeTests.swift) | — | 3 | — | Full orchestrator phases | Per-adapter stream contract tests | **Decompose** |
| [RemoteDelegateUsageSettlementTests.swift](../Tests/SwiftAgentHarnessTests/Core/SubAgentPool/RemoteDelegateUsageSettlementTests.swift) | — | 1 | — | Runtime + mock ACP | `SubAgentDelegateCompletionUsageMappingTests` | **Replace** |
| [SessionPersistenceHarnessTests.swift](../Tests/SwiftAgentHarnessTests/Backends/Persistence/SessionPersistenceHarnessTests.swift) | — | 1 | — | SwiftData read-through | — | **Keep** (in-memory, no network) |
| [RunLifecycleDurabilityTests.swift](../Tests/SwiftAgentHarnessTests/Backends/Persistence/RunLifecycleDurabilityTests.swift) (persistence) | — | 6 | `.serialized` | Restart reconciliation | — | **Keep** (no network) |

## Not Integration (despite names)

- `DockerSandboxNetworkTests` — argv inspection only
- `A2ASubAgentTransportAdapterTests` / `ACPStdioSubAgentTransportAdapterTests` — mock stream clients
- Most config/metadata-only `HarnessRuntimeSession` tests

## Unit Test Design Principles

1. Test SwiftAgentHarness types, not Vapor — stub `Request`/`Response` or call pure functions
2. Both sides of the wire — encode outbound → decode inbound; assert JSON schema
3. Hub as boundary — publish to `*TopicHub`, subscribe in-process; no socket
4. Inject seams — `AgentRuntimeSeamTests`, `HarnessRuntimeOutboundTestDoubles`
5. No `.serialized` unless unavoidable — per-test `ModelContainer` instances
6. TDD — write unit test first, then delete integration counterpart

## Success Criteria

- Default `swift test` does not start TCP servers or use `URLSession` against loopback
- `.serialized` removed from API layer tests
- Full suite completes in under 60 seconds on dev hardware
