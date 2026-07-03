import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgentPool boundary")
struct SubAgentPoolBoundaryTests {
    @Test("listSubAgents maps delegate tools to v2 rows")
    func listSubAgentsMapsDelegateRows() async {
        let pool = DefaultSubAgentPool()
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_research", description: "research", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a,
                effectClass: .readOnly,
                parallelHint: .parallelizable
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "list_conversations", description: "local", parameters: [], type: .function),
                source: .local
            ),
        ]

        let registry = await pool.listSubAgents(from: entries, routingContext: nil, conversationID: UUID())
        #expect(registry.count == 1)
        #expect(registry[0].delegateToolName == "delegate_research")
        #expect(registry[0].transportKind == ToolRegistryEntry.TransportKind.a2a.rawValue)
        #expect(registry[0].permissionPolicy == .askUser)
    }

    @Test("listSubAgents applies routing context filters consistently")
    func listSubAgentsAppliesRoutingFilters() async {
        let hostingPolicy = SubAgentHostingPolicyConfiguration(
            defaultPolicy: SubAgentHostingPolicy(),
            policiesByDelegateToolName: [
                "delegate_docs": SubAgentHostingPolicy(
                    hostPersonaID: "doc-agent",
                    delegationAllowlist: [],
                    authScopeTags: ["repo:read"],
                    routingDomain: "docs",
                    tenantScope: "default"
                ),
                "delegate_ops": SubAgentHostingPolicy(
                    hostPersonaID: "ops-agent",
                    delegationAllowlist: [],
                    authScopeTags: ["infra:write"],
                    routingDomain: "ops",
                    tenantScope: "prod"
                ),
            ],
            policiesByHostPersonaID: [:]
        )
        let pool = DefaultSubAgentPool(hostingPolicyConfiguration: hostingPolicy)
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_docs", description: "docs", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_ops", description: "ops", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a
            ),
        ]
        let context = SubAgentRoutingContext(
            hostPersonaID: "doc-agent",
            authScopeTags: ["repo:read"],
            routingDomain: "docs",
            tenantScope: "default"
        )
        let filtered = await pool.listSubAgents(from: entries, routingContext: context, conversationID: UUID())
        #expect(filtered.count == 1)
        #expect(filtered.first?.delegateToolName == "delegate_docs")
    }

    @Test("refreshSubAgentCatalog returns fetched entries")
    func refreshSubAgentCatalogReturnsFetchedEntries() async {
        let pool = DefaultSubAgentPool()
        let expected = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_refresh_probe", description: "refresh", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let entries = await pool.refreshSubAgentCatalog(conversationID: UUID()) { _ in
            [expected]
        }
        #expect(entries.count == 1)
        #expect(entries.first?.name == expected.name)
    }

    @Test("normalizeLaunchRequest maps spawn request fields")
    func normalizeLaunchRequestMapsSpawnRequestFields() {
        let pool = DefaultSubAgentPool()
        let userMessageID = UUID()
        let request = SubAgentSpawnRequest(
            context: .fork,
            userMessageID: userMessageID,
            modelRef: "test-model",
            runInBackground: true,
            userSystemPrompt: "legacy-prompt"
        )
        let normalized = pool.normalizeLaunchRequest(request)
        #expect(normalized.context == SubAgentLaunchContext.fork)
        #expect(normalized.userMessageID == userMessageID)
        #expect(normalized.modelRef == "test-model")
        #expect(normalized.userSystemPrompt == "legacy-prompt")
        #expect(normalized.runInBackground == true)
    }

    @Test("normalizeLaunchRequest strips reserved permission metadata keys")
    func normalizeLaunchRequestStripsReservedPermissionMetadata() {
        let pool = DefaultSubAgentPool()
        let request = SubAgentSpawnRequest(
            context: .isolated,
            taskDescription: "task",
            metadata: .object([
                "permissionAlreadyGranted": .boolean(true),
                "permissionPolicyOverride": .string("auto"),
                "custom": .string("ok"),
            ])
        )
        let normalized = pool.normalizeLaunchRequest(request)
        #expect(normalized.permissionAlreadyGranted == false)
        guard case .object(let object) = normalized.metadata else {
            Issue.record("Expected sanitized metadata object")
            return
        }
        #expect(object.count == 1)
        guard case .string("ok") = object["custom"] else {
            Issue.record("Expected custom metadata preserved")
            return
        }
        #expect(object["permissionAlreadyGranted"] == nil)
        #expect(object["permissionPolicyOverride"] == nil)
    }

    @Test("transport gate ignores client permissionAlreadyGranted metadata")
    func transportGateIgnoresClientPermissionMetadata() throws {
        let pool = DefaultSubAgentPool()
        let agentID = "delegate_test_\(UUID().uuidString.lowercased())"
        let spawnRequest = SubAgentSpawnRequest(
            context: .isolated,
            taskDescription: "task",
            subagentType: SubAgentTransportKind.a2a.rawValue,
            agentID: agentID,
            runInBackground: true,
            metadata: .object(["permissionAlreadyGranted": .boolean(true)])
        )
        let launchRequest = pool.normalizeLaunchRequest(spawnRequest)
        let launchPlan = try pool.planLaunch(launchRequest, parentConversationID: UUID())
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "test", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "test",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            permissionPolicy: .askUser,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let invocation = SubAgentTransportInvocationRequest(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: UUID()
        )
        #expect(SubAgentTransportPermissionGate.initialPhase(for: invocation) == .awaitingApproval)
    }

    @Test("transport gate honors internal permissionAlreadyGranted field")
    func transportGateHonorsInternalPermissionField() throws {
        let pool = DefaultSubAgentPool()
        let agentID = "delegate_test_\(UUID().uuidString.lowercased())"
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID,
                permissionAlreadyGranted: true
            ),
            parentConversationID: UUID()
        )
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "test", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "test",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            permissionPolicy: .askUser,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let invocation = SubAgentTransportInvocationRequest(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: UUID()
        )
        #expect(SubAgentTransportPermissionGate.initialPhase(for: invocation) == .running)
    }

    @Test("planLaunch uses fork path for fork context")
    func planLaunchForkPath() throws {
        let pool = DefaultSubAgentPool()
        let userMessageID = UUID()
        let request = SubAgentLaunchRequest(context: .fork, userMessageID: userMessageID)
        let plan = try pool.planLaunch(request, parentConversationID: UUID())
        #expect(plan.spawnPlan == .fork(userMessageID: userMessageID))
    }

    @Test("planLaunch keeps stable background handle when agent id provided")
    func planLaunchBackgroundHandleFromAgentID() throws {
        let pool = DefaultSubAgentPool()
        let request = SubAgentLaunchRequest(context: .isolated, runInBackground: true, agentID: "agent-handle-1")
        let plan = try pool.planLaunch(request, parentConversationID: UUID())
        #expect(plan.asyncHandleID == "agent-handle-1")
    }

    @Test("resolveSubAgent selects best agent from query constraints")
    func resolveSubAgentByQuery() async throws {
        let pool = DefaultSubAgentPool()
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_remote_research", description: "remote research", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_local_codegen", description: "local code generation", parameters: [], type: .a2aAgent),
                source: .local,
                transportKind: .local
            ),
        ]
        let request = SubAgentLaunchRequest(
            context: .isolated,
            agentQuery: SubAgentQuery(text: "codegen", transportKinds: ["in-process"])
        )
        let resolved = try await pool.resolveSubAgent(request, from: entries, conversationID: UUID())
        #expect(resolved.agentID == "delegate_local_codegen")
    }

    @Test("resolveSubAgent keeps explicit id over query")
    func resolveSubAgentExplicitIDPrecedence() async throws {
        let pool = DefaultSubAgentPool()
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_remote_research", description: "remote research", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a
            )
        ]
        let request = SubAgentLaunchRequest(
            context: .isolated,
            agentID: "delegate_remote_research",
            agentQuery: SubAgentQuery(text: "something-else")
        )
        let resolved = try await pool.resolveSubAgent(request, from: entries, conversationID: UUID())
        #expect(resolved.agentID == "delegate_remote_research")
    }

    @Test("adapter resolution falls back to in-process")
    func adapterResolutionFallback() async {
        let pool = DefaultSubAgentPool()
        let request = SubAgentLaunchRequest(context: .isolated)
        let adapter = await pool.selectTransportAdapter(for: request, entries: [], conversationID: nil)
        #expect(adapter?.transportKind == .inProcess)
    }

    @Test("delegate transport mapping uses explicit environment metadata")
    func delegateTransportMappingUsesEnvironmentMetadata() async {
        let pool = DefaultSubAgentPool()
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_http_proxy", description: "proxy", parameters: [], type: .a2aAgent),
                source: .local,
                transportKind: .local,
                executionEnvironment: .init(
                    kind: .local,
                    adapterID: SubAgentTransportKind.customEndpoint.rawValue,
                    isolationLevel: .inProcess
                )
            ),
        ]
        let registry = await pool.listSubAgents(from: entries, routingContext: nil, conversationID: UUID())
        #expect(registry.count == 1)
        #expect(registry[0].transportKind == SubAgentTransportKind.customEndpoint.rawValue)
    }

    @Test("resolveSubAgent projects matched entry transport kind onto request")
    func resolveSubAgentProjectsMatchedTransportKind() async throws {
        let pool = DefaultSubAgentPool()
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_http_proxy", description: "proxy", parameters: [], type: .a2aAgent),
                source: .local,
                executionEnvironment: .init(
                    kind: .local,
                    adapterID: SubAgentTransportKind.customEndpoint.rawValue,
                    isolationLevel: .inProcess
                )
            )
        ]
        let request = SubAgentLaunchRequest(
            context: .isolated,
            agentID: "delegate_http_proxy"
        )
        let resolved = try await pool.resolveSubAgent(
            request,
            from: entries,
            conversationID: UUID()
        )
        #expect(resolved.subagentType == SubAgentTransportKind.customEndpoint.rawValue)
    }

    @Test("resolveSubAgent denies target outside host allowlist")
    func resolveSubAgentHostAllowlistDenied() async {
        let hostingPolicy = SubAgentHostingPolicyConfiguration(
            defaultPolicy: SubAgentHostingPolicy(),
            policiesByDelegateToolName: [
                "delegate_alpha": SubAgentHostingPolicy(
                    hostPersonaID: "coding-agent",
                    delegationAllowlist: [],
                    authScopeTags: ["repo:write"],
                    routingDomain: "engineering",
                    tenantScope: "default"
                ),
                "delegate_beta": SubAgentHostingPolicy(
                    hostPersonaID: "coding-agent",
                    delegationAllowlist: [],
                    authScopeTags: ["repo:write"],
                    routingDomain: "engineering",
                    tenantScope: "default"
                ),
            ],
            policiesByHostPersonaID: [
                "coding-agent": SubAgentHostingPolicy(
                    hostPersonaID: "coding-agent",
                    delegationAllowlist: ["delegate_alpha"],
                    authScopeTags: ["repo:write"],
                    routingDomain: "engineering",
                    tenantScope: "default"
                )
            ]
        )
        let pool = DefaultSubAgentPool(hostingPolicyConfiguration: hostingPolicy)
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_alpha", description: "alpha", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_beta", description: "beta", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a
            ),
        ]
        let deniedRequest = SubAgentLaunchRequest(
            context: .isolated,
            agentID: "delegate_beta",
            routingContext: SubAgentRoutingContext(
                hostPersonaID: "coding-agent",
                authScopeTags: ["repo:write"],
                routingDomain: "engineering",
                tenantScope: "default"
            )
        )
        await #expect(throws: ConversationServiceError.self) {
            _ = try await pool.resolveSubAgent(deniedRequest, from: entries, conversationID: UUID())
        }
    }

    @Test("invokeSubAgent delegates in-process execution to host")
    func invokeSubAgentInProcessDelegatesToHost() async throws {
        let pool = DefaultSubAgentPool()
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_local_worker", description: "local worker", parameters: [], type: .a2aAgent),
            source: .local,
            executionEnvironment: .init(
                kind: .local,
                adapterID: SubAgentTransportKind.inProcess.rawValue,
                isolationLevel: .inProcess
            )
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: "delegate_local_worker",
            displayName: "delegate_local_worker",
            description: "local worker",
            delegateToolName: "delegate_local_worker",
            source: .local,
            transportKind: SubAgentTransportKind.inProcess.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.inProcess.rawValue,
                agentID: "delegate_local_worker"
            ),
            parentConversationID: UUID()
        )
        let result = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: UUID()
        )
        #expect(result.outcome == SubAgentTransportInvocationOutcome.delegatedToHostInProcess)
    }

    @Test("invokeSubAgent returns remote handle for A2A")
    func invokeSubAgentA2AStartsRemote() async throws {
        let pool = DefaultSubAgentPool()
        let agentID = "delegate_remote_worker_\(UUID().uuidString.lowercased())"
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "remote worker", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "remote worker",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID
            ),
            parentConversationID: UUID()
        )
        let result = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: UUID()
        )
        switch result.outcome {
        case .remoteStarted(let correlation):
            #expect(correlation.transportKind == .a2a)
            #expect(correlation.sessionHandleID == agentID)
            #expect(correlation.completionHandleID != nil)
            #expect(result.delegateEvents.count == 1)
            #expect(result.delegateEvents[0].phase == .awaitingApproval)
            #expect(result.delegateEvents[0].eventTrustLevel == SubAgentTrustLevel.knownParty.rawValue)
        default:
            Issue.record("Expected remoteStarted outcome for A2A transport")
        }
    }

    @Test("invokeSubAgent fails closed when ACP manager unavailable")
    func invokeSubAgentACPStdioFailsClosedWhenManagerMissing() async throws {
        let pool = DefaultSubAgentPool()
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_acp_worker", description: "acp worker", parameters: [], type: .acpAgent),
            source: .unknown,
            executionEnvironment: .init(
                kind: .mcp,
                adapterID: SubAgentTransportKind.acpStdio.rawValue,
                isolationLevel: .remoteManaged
            )
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: "delegate_acp_worker",
            displayName: "delegate_acp_worker",
            description: "acp worker",
            delegateToolName: "delegate_acp_worker",
            source: .unknown,
            transportKind: SubAgentTransportKind.acpStdio.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.acpStdio.rawValue,
                runInBackground: true,
                agentID: "delegate_acp_worker",
                permissionAlreadyGranted: true
            ),
            parentConversationID: UUID()
        )
        let invokeResult = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: UUID()
        )
        guard case .remoteStarted = invokeResult.outcome else {
            Issue.record("Expected remoteStarted when manager missing")
            return
        }
    }

    @Test("invokeSubAgent returns remote correlation for custom endpoint")
    func invokeSubAgentCustomEndpointStartsRemote() async throws {
        let endpointURL = URL(string: "https://example.test/delegate")!
        let configuration = SubAgentCustomEndpointConfiguration(
            bindingsByDelegateToolName: [
                "delegate_custom_worker": CustomEndpointBinding(url: endpointURL),
            ]
        )
        final class MockCustomEndpointExecutor: CustomEndpointDelegateExecuting, @unchecked Sendable {
            func invoke(
                endpoint: CustomEndpointBinding,
                instructions: String,
                lifecycleID: String,
                toolCallID: String?
            ) async throws -> CustomEndpointDelegateResponse {
                CustomEndpointDelegateResponse(content: "done", usage: nil)
            }
        }
        let pool = DefaultSubAgentPool(
            adapters: SubAgentDefaultAdapters.make(
                customEndpointConfiguration: configuration,
                customEndpointExecutor: MockCustomEndpointExecutor()
            )
        )
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_custom_worker", description: "custom worker", parameters: [], type: .a2aAgent),
            source: .local,
            executionEnvironment: .init(
                kind: .local,
                adapterID: SubAgentTransportKind.customEndpoint.rawValue,
                isolationLevel: .inProcess
            )
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: "delegate_custom_worker",
            displayName: "delegate_custom_worker",
            description: "custom worker",
            delegateToolName: "delegate_custom_worker",
            source: .local,
            transportKind: SubAgentTransportKind.customEndpoint.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.customEndpoint.rawValue,
                runInBackground: true,
                agentID: "delegate_custom_worker"
            ),
            parentConversationID: UUID()
        )
        let result = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: UUID()
        )
        switch result.outcome {
        case .remoteStarted(let correlation):
            #expect(correlation.transportKind == .customEndpoint)
            #expect(correlation.sessionHandleID == endpointURL.absoluteString)
            #expect(correlation.completionHandleID != nil)
        default:
            Issue.record("Expected remoteStarted outcome for custom endpoint transport")
        }
    }

    @Test("cancelTransport routes request to adapter")
    func cancelTransportRoutesToAdapter() async throws {
        let pool = DefaultSubAgentPool()
        let agentID = "delegate_remote_worker_\(UUID().uuidString.lowercased())"
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID
            ),
            parentConversationID: UUID()
        )
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "remote worker", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "remote worker",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let invokeResult = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: UUID()
        )
        guard case let .remoteStarted(correlation) = invokeResult.outcome else {
            Issue.record("Expected remote correlation")
            return
        }
        let cancelResult = try await pool.cancelTransport(
            SubAgentTransportCancellationRequest(
                lifecycleID: correlation.lifecycleID,
                transportKind: .a2a,
                sessionHandleID: correlation.sessionHandleID,
                completionHandleID: correlation.completionHandleID
            )
        )
        #expect(cancelResult.disposition == .cancelled)
        #expect(cancelResult.delegateEvents.first?.phase == .failed)
        #expect(cancelResult.delegateEvents.first?.error == "cancelled_by_operator")
    }

    @Test("recoverTransport returns adapter recovery result")
    func recoverTransportReturnsResult() async throws {
        let pool = DefaultSubAgentPool()
        let parentConversationID = UUID()
        let agentID = "delegate_remote_worker_\(UUID().uuidString.lowercased())"
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "remote worker", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "remote worker",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID
            ),
            parentConversationID: parentConversationID
        )
        let invokeResult = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: parentConversationID
        )
        guard case let .remoteStarted(correlation) = invokeResult.outcome else {
            Issue.record("Expected remote correlation")
            return
        }
        let result = try await pool.recoverTransport(
            SubAgentTransportRecoveryRequest(
                lifecycleID: correlation.lifecycleID,
                transportKind: correlation.transportKind,
                sessionHandleID: correlation.sessionHandleID,
                completionHandleID: correlation.completionHandleID
            )
        )
        #expect(result.disposition == .resumed)
        #expect(result.delegateEvents.first?.phase == .awaitingApproval)
    }

    @Test("streamDelegateEvents returns empty stream for default adapters")
    func streamDelegateEventsDefaultIsEmpty() async {
        let pool = DefaultSubAgentPool()
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: "lifecycle-1",
            transportKind: .a2a,
            sessionHandleID: "delegate_remote_worker",
            completionHandleID: "handle-1"
        )
        let stream = await pool.streamDelegateEvents(
            SubAgentTransportDelegateEventsRequest(correlation: correlation, parentConversationID: UUID())
        )
        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("resolveTransportPermission transitions awaiting approval to running")
    func resolveTransportPermissionTransitionsToRunning() async throws {
        let pool = DefaultSubAgentPool()
        let parentConversationID = UUID()
        let agentID = "delegate_remote_worker_\(UUID().uuidString.lowercased())"
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "remote worker", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "remote worker",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID
            ),
            parentConversationID: parentConversationID
        )
        let invokeResult = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: parentConversationID
        )
        guard case let .remoteStarted(correlation) = invokeResult.outcome else {
            Issue.record("Expected remote correlation")
            return
        }
        let approvalResult = try await pool.resolveTransportPermission(
            SubAgentTransportPermissionResolutionRequest(
                lifecycleID: correlation.lifecycleID,
                transportKind: correlation.transportKind,
                sessionHandleID: correlation.sessionHandleID,
                completionHandleID: correlation.completionHandleID,
                parentConversationID: parentConversationID,
                approvalRoute: .user,
                decision: .approved,
                source: "test.approval"
            )
        )
        #expect(approvalResult.disposition == .resumed)
        #expect(approvalResult.delegateEvents.first?.phase == .running)
    }

    @Test("askParent invoke starts awaiting approval")
    func askParentInvokeAwaitingApproval() async throws {
        let pool = DefaultSubAgentPool()
        let parentConversationID = UUID()
        let agentID = "delegate_ask_parent_\(UUID().uuidString.lowercased())"
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "remote worker", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "remote worker",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            permissionPolicy: .askParent,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID
            ),
            parentConversationID: parentConversationID
        )
        let invokeResult = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: parentConversationID
        )
        #expect(invokeResult.delegateEvents.first?.phase == .awaitingApproval)
        #expect(invokeResult.delegateEvents.first?.approvalRoute == .parent)
    }

    @Test("cancelTransport failed event omits completion usage")
    func cancelTransportOmitsCompletionUsage() async throws {
        let pool = DefaultSubAgentPool()
        let parentConversationID = UUID()
        let agentID = "delegate_cancel_\(UUID().uuidString.lowercased())"
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "remote worker", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "remote worker",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID
            ),
            parentConversationID: parentConversationID
        )
        let invokeResult = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: parentConversationID
        )
        guard case let .remoteStarted(correlation) = invokeResult.outcome else {
            Issue.record("Expected remote correlation")
            return
        }
        let cancelResult = try await pool.cancelTransport(
            SubAgentTransportCancellationRequest(
                lifecycleID: correlation.lifecycleID,
                transportKind: correlation.transportKind,
                sessionHandleID: correlation.sessionHandleID,
                completionHandleID: correlation.completionHandleID
            )
        )
        #expect(cancelResult.delegateEvents.first?.phase == .failed)
        #expect(cancelResult.delegateEvents.first?.completionUsage == nil)
    }

    @Test("recoverTransport cancelled disposition omits completion usage")
    func recoverTransportOmitsCompletionUsage() async throws {
        let pool = DefaultSubAgentPool()
        let parentConversationID = UUID()
        let agentID = "delegate_recover_cancel_\(UUID().uuidString.lowercased())"
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "remote worker", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "remote worker",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID
            ),
            parentConversationID: parentConversationID
        )
        let invokeResult = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: parentConversationID
        )
        guard case let .remoteStarted(correlation) = invokeResult.outcome else {
            Issue.record("Expected remote correlation")
            return
        }
        _ = try await pool.cancelTransport(
            SubAgentTransportCancellationRequest(
                lifecycleID: correlation.lifecycleID,
                transportKind: correlation.transportKind,
                sessionHandleID: correlation.sessionHandleID,
                completionHandleID: correlation.completionHandleID
            )
        )
        let result = try await pool.recoverTransport(
            SubAgentTransportRecoveryRequest(
                lifecycleID: correlation.lifecycleID,
                transportKind: correlation.transportKind,
                sessionHandleID: correlation.sessionHandleID,
                completionHandleID: correlation.completionHandleID
            )
        )
        #expect(result.disposition == .cancelled)
        #expect(result.delegateEvents.first?.phase == .failed)
        #expect(result.delegateEvents.first?.completionUsage == nil)
    }
}
