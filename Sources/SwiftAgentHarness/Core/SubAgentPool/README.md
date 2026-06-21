# Sub-Agent Pool

This folder implements the harness **Sub-Agent Pool** spec: **delegation** (local or remote) as a resource pool with registry, lifecycle, transports, and **delegate tools** exposed through the Tool System. The harness exposes a first-class pool boundary (`SubAgentPooling` / `DefaultSubAgentPool`) for registry mapping, delegate classification, normalized launch planning, transport adapters, lifecycle coordination, and completion handoff.

Production wiring is assembled by **`SubAgentPoolRuntimeWiring`** and injected from the host app's composition root (typically via **`HarnessRuntimeSessionFactory`**).

## Boundary: SwiftAgentKit vs harness

| Concern | SwiftAgentKit | Harness / host |
|--------|----------------|----------------|
| Remote ACP wire I/O | `ACPManager.streamAgentCall`, `cancelAgentCall`, `ACPDelegateStreamEvent` | **`ACPStdioSubAgentTransportAdapter`** (pool-owned execution) |
| Orchestrator integration | `SwiftAgentKitOrchestrator(..., acpManager:, config.acpIntegration)` | [`OrchestratorRuntimeService.setupOrchestrator`](../ConversationManager/OrchestratorRuntimeService.swift): **`acpIntegration: .registrationOnly`** when manager present |
| ACP manager injection | `ACPManager.initialize(...)` | [`ConversationStartupService.setACPManager`](../ConversationManager/ConversationStartupService.swift) + **`SubAgentPoolACPManagerProvider`**; host boots stdio clients with swappable delegate boxes |
| Remote A2A wire I/O | `A2AManager.streamAgentCall`, `cancelAgentCall`, agent cards / task lifecycle | **`A2ASubAgentTransportAdapter`** (pool-owned execution) |
| Orchestrator integration | `SwiftAgentKitOrchestrator(..., a2aManager:, config.a2aIntegration)` | [`OrchestratorRuntimeService.setupOrchestrator`](../ConversationManager/OrchestratorRuntimeService.swift): **`a2aIntegration: .registrationOnly`** when manager present — tools registered, inline `agentCall` disabled |
| A2A manager injection | `A2AManager.initialize(...)` | [`ConversationStartupService.setA2AManager`](../ConversationManager/ConversationStartupService.swift) updates both orchestrator catalog and **`SubAgentPoolA2AManagerProvider`** |
| **Delegate tools** (harness) | Tool descriptors in orchestrator registration | Classified via `SubAgentPooling.isDelegateTool`; **spawn, model-turn, and slash-command** dispatch route through **`SubAgentSpawnService.invokeDelegateToolFromModelTurn`** |
| In-process nested agent | N/A in harness layer | **`InProcessSubAgentTransportAdapter`** — host spawn flow |
| Custom HTTP delegates | N/A | **`CustomEndpointSubAgentTransportAdapter`** — POST contract below |

**Statement:** Remote delegate **execution** is owned by **SubAgentPool transport adapters**. The orchestrator retains **registration** of A2A/ACP-derived tool definitions only.

## Host integration

At boot, the host app typically:

1. Loads delegate endpoint config (`a2a_config.json`, `acp_config.json`, `PromptConfig.json` → `subAgentCustomEndpoints`).
2. Boots long-lived ACP stdio clients and registers A2A/ACP tool definitions with the orchestrator (registration only).
3. Injects `ACPManager` / `A2AManager` into **`SubAgentPoolACPManagerProvider`** / **`SubAgentPoolA2AManagerProvider`**.
4. Wires **`SubAgentPoolRuntimeWiring`** with spawn, lifecycle publishing, and completion handoff ports.

## Transport adapters

| Adapter | Behavior |
|---------|----------|
| `in-process` | Returns `delegatedToHostInProcess`; host creates child conversation |
| `a2a` | Registers session in `SubAgentRemoteTransportSessionStore`, streams `A2ADelegateStreamEvent` → `SubAgentDelegateEvent`, cancels via `cancelAgentCall(invocationID:)` |
| `custom-endpoint` | POST JSON to configured URL; sync response → `.done` |
| `acp-stdio` | Registers session, swaps `HarnessACPClientDelegate` on booted client via delegate box, streams `ACPDelegateStreamEvent` → `SubAgentDelegateEvent`, cancels via `cancelAgentCall(invocationID:)` |

### Custom-endpoint HTTP contract (internal)

**Request:** `POST {endpointURL}`

```json
{ "instructions": "...", "toolCallId": "...", "lifecycleId": "..." }
```

**Response (sync v1):**

```json
{ "content": "...", "usage": { "promptTokens": 0, "completionTokens": 0, "totalTokens": 0, "costUSD": 0.0 } }
```

Bindings are loaded from `PromptConfig.json` → `subAgentCustomEndpoints` keyed by delegate tool name.

### Shared session store

`SubAgentRemoteTransportSessionStore` holds session registry, event bus, permission gate, cancel, and recovery. Adapters register sessions and push real lifecycle events; production cancel/deny paths do **not** emit synthetic completion usage.

### ACP permission routing

- **Invoke-time:** `SubAgentTransportPermissionGate` defers execution for `ask-user` and `ask-parent` until `resolveTransportPermission` (or tool approval bridged via `ToolApprovalRuntimeService`).
- **Mid-RPC:** `HarnessACPClientDelegate.requestPermission` bubbles through `SubAgentACPPermissionCoordinator`: lifecycle transitions to `awaiting-approval`, publishes `tool.approvalRequired`, registers pending approval (`subagent-acp-permission:{lifecycleID}:{requestID}`), and resumes the blocked ACP RPC when approved or denied.
- **Auto / pre-granted:** first permission option is selected without bubble-back.

### ACP capability advertising vs enforcement

Boot-time client capabilities in `acp_config.json` and the host's ACP manager bootstrap are **agent-class-broad** (what the ACP child may attempt during handshake). **Fine-grained allow/deny** is enforced at RPC time in `HarnessACPClientDelegate.requireTool` via the Tool System gateway with `inputTrustRaw = unknown-party`. An unprivileged child may see terminal/fs in the handshake but is rejected at call time when policy denies — this is intentional defense-in-depth. A capability **profile pool** (one long-lived client per coarse profile) is deferred until multiple ACP agent classes need different advertised shapes.

## Delegate dispatch entry points

All remote delegate invocations share lifecycle IDs, topics, cancel, and completion handoff:

1. **REST / memory spawn** — `SubAgentSpawnService.spawnSubAgentViaPool`
2. **Model tool turn** — `AgentLoopToolDispatch` → `SubAgentDelegateInvocationService` → pool
3. **Slash commands** — `SlashCommandDispatchService.executeSlashToolInvocation` → pool when target is a delegate tool

Model-turn invocations seed lifecycle with `permissionAlreadyGranted` metadata when the gateway has already approved the tool.

## Configuration → tool surface

1. **`a2a_config.json`** — `a2aServers` maps named servers. Empty config means no remote agents until entries are added.
2. **`acp_config.json`** — `agentBootCalls` boots long-lived ACP stdio clients (`advertiseTerminal` defaults to `false`).
3. A2A/ACP contribute agent tool definitions into the orchestrator catalog (registration only).
4. Execution uses pool transport adapters with injected managers.

## Lifecycle and observability

Sub-agent lifecycle snapshots publish on:

- `subagent/{conversationId}/{path}/events`
- `subagent/{conversationId}/{path}/state`

Long-running delegates use pending handles and `CompletionAnnouncePayload` for push-based completion.

### Orphan recovery (v1)

On gateway restart, stale child runs receive a durable `run_orphaned` transcript marker (Conversation Manager startup scan). Sub-Agent Pool then:

1. Rebuilds lifecycle entries from persisted nested conversations.
2. Publishes `subagent.orphaned` on the parent conversation topic (`RuntimeLifecycleEventName.subagentOrphaned`) and updates `subagent/{conv}/{path}/events` with `phase: orphaned`.
3. Skips notification when the child was already cancelled (`run_cancelled` marker present).

**Intentional v1 limits:**

- **Remote transport `recover()`** — replays in-memory session state only (`awaitingApproval` / `running` / `cancelled`). After restart the session store is empty (`session_not_found`); orphan closure relies on the transcript scan above, not A2A task re-attach.
- **Auto-resume** — not implemented; parent UI should offer discard / re-spawn / inspect.
- **Completion usage on non-terminal phases** — lifecycle snapshots omit `completionUsage` unless `phase == done` (cancel/recover/orphan telemetry does not carry stale usage; ledger settlement remains success-only).

Operator controls:

- `GET /api/conversations/{parentConversationID}/sub-agents/active`
- `POST /api/conversations/{parentConversationID}/sub-agents/{lifecycleID}/cancel`
- `POST /api/conversations/{conversationID}/completion-announcements`

## Related modules

- **Model Pool:** [`../ModelPool/`](../ModelPool/) — model scheduling; delegate usage can link to [`DelegateCostLedger`](../ModelPool/DelegateCostTracking.swift)
- **Tool System:** [`../ToolSystem/README.md`](../ToolSystem/README.md)
- **Agent Runtime:** [`../AgentRuntime/README.md`](../AgentRuntime/README.md)
