import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgentExecutionCoordinator")
struct SubAgentExecutionCoordinatorTests {
    private func makeParentConversation() -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: Model(
                protocol: .openAIAPI,
                modelName: "depth-gate-test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion, .tools],
                modelProtocol: .openAIAPI
            ),
            systemPrompt: "sys",
            interactionMode: .agent
        )
    }

    private func makeCoordinator(pool: any SubAgentPooling = DefaultSubAgentPool(hostingPolicyConfiguration: .empty)) -> SubAgentExecutionCoordinator {
        SubAgentExecutionCoordinator(subAgentPool: pool)
    }

    private func prepareLaunch(
        coordinator: SubAgentExecutionCoordinator,
        request: SubAgentSpawnRequest,
        orchestrationEntries: [ToolRegistryEntry] = [],
        modeProfileMaxDepth: Int?,
        parentDepth: Int
    ) async throws -> SubAgentPreparedLaunch {
        let parentConversation = makeParentConversation()
        return try await coordinator.prepareLaunch(
            parentConversationID: parentConversation.id,
            parentConversation: parentConversation,
            request: request,
            orchestrationEntries: orchestrationEntries,
            modeSubAgentAllowList: ["*"],
            modeProfileMaxDepth: modeProfileMaxDepth,
            parentDepth: parentDepth
        )
    }

    @Test("prepareLaunch blocks spawn at in-process transport cap when mode profile maxDepth is nil")
    func transportCapBlocksAtDefaultInProcessDepth() async {
        let coordinator = makeCoordinator()
        let request = SubAgentSpawnRequest(
            context: .isolated,
            taskDescription: "nested task"
        )
        do {
            _ = try await prepareLaunch(
                coordinator: coordinator,
                request: request,
                modeProfileMaxDepth: nil,
                parentDepth: 3
            )
            Issue.record("Expected recursion depth exceeded at in-process cap")
        } catch let ConversationServiceError.runtimeLaneUnavailable(reason) {
            #expect(reason == "subagent_recursion_depth_exceeded:3")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("prepareLaunch allows spawn below in-process transport cap")
    func transportCapAllowsShallowSpawn() async throws {
        let coordinator = makeCoordinator()
        let request = SubAgentSpawnRequest(
            context: .isolated,
            taskDescription: "nested task"
        )
        let prepared = try await prepareLaunch(
            coordinator: coordinator,
            request: request,
            modeProfileMaxDepth: nil,
            parentDepth: 2
        )
        #expect(prepared.launchPlan.delegationContext.transportKind == .inProcess)
    }

    @Test("prepareLaunch uses strictest cap among registry and mode profile")
    func strictestCapWins() async {
        let agentID = "delegate_research"
        let orchestrationEntries = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: agentID, description: "research", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a
            ),
        ]
        let coordinator = makeCoordinator()
        let request = SubAgentSpawnRequest(
            context: .isolated,
            taskDescription: "nested task",
            agentID: agentID
        )
        do {
            _ = try await prepareLaunch(
                coordinator: coordinator,
                request: request,
                orchestrationEntries: orchestrationEntries,
                modeProfileMaxDepth: 1,
                parentDepth: 1
            )
            Issue.record("Expected mode profile cap to win over transport cap")
        } catch let ConversationServiceError.runtimeLaneUnavailable(reason) {
            #expect(reason == "subagent_recursion_depth_exceeded:1")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("prepareLaunch enforces mode profile cap when registry entry has no maxRecursionDepth")
    func profileCapWithoutRegistryCap() async {
        let agentID = "delegate_research"
        let orchestrationEntries = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: agentID, description: "research", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a
            ),
        ]
        let coordinator = makeCoordinator()
        let request = SubAgentSpawnRequest(
            context: .isolated,
            taskDescription: "nested task",
            agentID: agentID
        )
        do {
            _ = try await prepareLaunch(
                coordinator: coordinator,
                request: request,
                orchestrationEntries: orchestrationEntries,
                modeProfileMaxDepth: 1,
                parentDepth: 1
            )
            Issue.record("Expected mode profile maxDepth to block spawn")
        } catch let ConversationServiceError.runtimeLaneUnavailable(reason) {
            #expect(reason == "subagent_recursion_depth_exceeded:1")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("prepareLaunch applies absolute fallback when all caps are nil")
    func absoluteFallbackWhenAllCapsNil() async {
        let coordinator = makeCoordinator(pool: UncappedTransportSubAgentPool())
        let request = SubAgentSpawnRequest(
            context: .isolated,
            taskDescription: "nested task"
        )
        do {
            _ = try await prepareLaunch(
                coordinator: coordinator,
                request: request,
                modeProfileMaxDepth: nil,
                parentDepth: SubAgentRecursionLimits.absoluteMaxDepthFallback
            )
            Issue.record("Expected absolute fallback to block spawn")
        } catch let ConversationServiceError.runtimeLaneUnavailable(reason) {
            #expect(reason == "subagent_recursion_depth_exceeded:\(SubAgentRecursionLimits.absoluteMaxDepthFallback)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct UncappedTransportAdapter: SubAgentTransportAdapting {
    let id = "uncapped-test"
    let transportKind: SubAgentTransportKind = .inProcess
    let capabilities = SubAgentTransportCapabilities(
        transportKind: .inProcess,
        supportsStreaming: false,
        supportsLongRunning: false,
        maxRecursionDepth: nil,
        useClasses: []
    )

    func invoke(_ request: SubAgentTransportInvocationRequest) async throws -> SubAgentTransportInvocationResult {
        _ = request
        return SubAgentTransportInvocationResult(outcome: .delegatedToHostInProcess)
    }
}

private struct UncappedTransportSubAgentPool: SubAgentPooling {
    let completionHandoffOwner: any SubAgentCompletionHandoffOwning = SubAgentCompletionHandoffOwner()
    private let backingPool = DefaultSubAgentPool(
        adapters: [UncappedTransportAdapter()],
        hostingPolicyConfiguration: .empty
    )

    func delegateToolNames(from entries: [ToolRegistryEntry]) async -> Set<String> {
        await backingPool.delegateToolNames(from: entries)
    }

    func listSubAgents(
        from entries: [ToolRegistryEntry],
        routingContext: SubAgentRoutingContext?,
        conversationID: UUID?
    ) async -> [SubAgentRegistryEntry] {
        await backingPool.listSubAgents(from: entries, routingContext: routingContext, conversationID: conversationID)
    }

    func refreshSubAgentCatalog(
        conversationID: UUID?,
        fetchEntries: @escaping (UUID?) async -> [ToolRegistryEntry]
    ) async -> [ToolRegistryEntry] {
        await backingPool.refreshSubAgentCatalog(conversationID: conversationID, fetchEntries: fetchEntries)
    }

    func normalizeLaunchRequest(_ request: SubAgentSpawnRequest) -> SubAgentLaunchRequest {
        backingPool.normalizeLaunchRequest(request)
    }

    func resolveSubAgent(
        _ request: SubAgentLaunchRequest,
        from entries: [ToolRegistryEntry],
        conversationID: UUID?
    ) async throws -> SubAgentLaunchRequest {
        try await backingPool.resolveSubAgent(request, from: entries, conversationID: conversationID)
    }

    func planLaunch(_ request: SubAgentLaunchRequest, parentConversationID: UUID) throws -> SubAgentLaunchPlan {
        try backingPool.planLaunch(request, parentConversationID: parentConversationID)
    }

    func selectTransportAdapter(
        for request: SubAgentLaunchRequest,
        entries: [ToolRegistryEntry],
        conversationID: UUID?
    ) async -> (any SubAgentTransportAdapting)? {
        UncappedTransportAdapter()
    }

    func invokeSubAgent(
        launchPlan: SubAgentLaunchPlan,
        registryEntry: SubAgentRegistryEntry,
        toolEntry: ToolRegistryEntry,
        parentConversationID: UUID
    ) async throws -> SubAgentTransportInvocationResult {
        try await backingPool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: parentConversationID
        )
    }

    func streamDelegateEvents(
        _ request: SubAgentTransportDelegateEventsRequest
    ) async -> AsyncStream<SubAgentDelegateEvent> {
        await backingPool.streamDelegateEvents(request)
    }

    func cancelTransport(_ request: SubAgentTransportCancellationRequest) async throws -> SubAgentTransportCancellationResult {
        try await backingPool.cancelTransport(request)
    }

    func resolveTransportPermission(
        _ request: SubAgentTransportPermissionResolutionRequest
    ) async throws -> SubAgentTransportPermissionResolutionResult {
        try await backingPool.resolveTransportPermission(request)
    }

    func recoverTransport(_ request: SubAgentTransportRecoveryRequest) async throws -> SubAgentTransportRecoveryResult {
        try await backingPool.recoverTransport(request)
    }

    func isDelegateTool(entry: ToolRegistryEntry) -> Bool {
        backingPool.isDelegateTool(entry: entry)
    }

    func permissionPolicy(for entry: ToolRegistryEntry) -> SubAgentPermissionPolicy {
        backingPool.permissionPolicy(for: entry)
    }

    func trustLevel(for entry: ToolRegistryEntry) -> SubAgentTrustLevel {
        backingPool.trustLevel(for: entry)
    }

    func maxRecursionDepth(for entry: ToolRegistryEntry) -> Int? {
        nil
    }
}
