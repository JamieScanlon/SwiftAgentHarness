import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

// MARK: - Outbound (AgentRuntimeSessionService collaborators)

protocol ToolApprovalRuntimeServicing: Sendable {
    func consumeTimedOutToolApprovalsForRuntime(
        conversationID: UUID,
        runID: UUID?,
        iteration: Int?,
        modelID: UUID?,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async
    func configurationApplyingToolApprovals(
        _ configuration: HarnessRuntimeSession.Configuration,
        conversationID: UUID,
        runID: UUID?
    ) async -> HarnessRuntimeSession.Configuration
    func approvalContractSpec(
        toolName: String,
        route: ToolApprovalRoute,
        isElevated: Bool,
        arguments: JSON?
    ) -> ToolApprovalContractSpec
    func registerPendingToolApproval(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute,
        isElevated: Bool,
        requestedAt: Date
    ) async -> Bool
    func registerPendingToolApproval(
        conversationID: UUID,
        runID: UUID?,
        call: ToolCallRequest,
        route: ToolApprovalRoute,
        isElevated: Bool,
        requestedAt: Date
    ) async -> Bool
    func toolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute
    ) async -> ToolApprovalResolution?
    func waitForToolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute
    ) async throws -> ToolApprovalResolution
}

protocol OrchestratorRuntimeToolPolicyServicing: Sendable {
    func allToolRegistryEntriesForOrchestration(orchestrator: SwiftAgentKitOrchestrator) async -> [ToolRegistryEntry]
    func buildToolTurnPolicySnapshot(
        allEntries: [ToolRegistryEntry],
        conversation: ModelConversation,
        configuration: HarnessRuntimeSession.Configuration
    ) async -> RuntimeToolTurnPolicySnapshot
    func orchestratorInvocationOptions(
        for conversation: ModelConversation?,
        toolTurnSnapshot: RuntimeToolTurnPolicySnapshot?,
        effectiveToolEntries: [ToolRegistryEntry],
        availabilitySnapshots: [RuntimeToolAvailabilitySnapshot],
        forcedToolChoiceRequired: Bool
    ) async -> OrchestratorInvocationOptions
    func acquireOrchestrator(
        conversation: ModelConversation,
        model: Model
    ) async -> OrchestratorAcquisition?
    func releaseOrchestrator(_ handle: OrchestratorHandle) async
    func buildTransientOrchestratorForCatalog(
        model: Model,
        conversation: ModelConversation?
    ) async -> SwiftAgentKitOrchestrator?
}

protocol ContextProjectionTransformServicing: Sendable {
    func transformedContextMessages(
        from originalMessages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        configuration: HarnessRuntimeSession.Configuration,
        gatingOverride: ContextCompactionGatingOptions?
    ) async -> [Message]
}

protocol SlashCommandRuntimeDispatching: Sendable {
    func runSlashCommandIfNeeded(_ text: String, conversationID: UUID) async throws -> ChatStreamResponse?
    func processControlInputBoundary(
        text: String,
        conversationID: UUID,
        trustClass: TrustPolicyClass?,
        senderLabel: String?
    ) async throws -> ControlInputBoundaryOutcome
}

struct AgentRuntimeOutboundCollaborators: Sendable {
    let toolApproval: any ToolApprovalRuntimeServicing
    let orchestratorRuntime: any OrchestratorRuntimeToolPolicyServicing
    let contextProjection: any ContextProjectionTransformServicing
    let lifecycle: any ConversationLifecycleServicing
    let slashCommand: any SlashCommandRuntimeDispatching
}

// MARK: - Inbound (peers calling into agent runtime)

protocol AgentRuntimeOrchestratorBinding: Sendable {
    func orchestrator(for conversationID: UUID) async -> SwiftAgentKitOrchestrator?
    func lifecycleSnapshot(for conversationID: UUID?) async -> ChatRuntimeLifecycle
    func clearOrchestratorBinding() async
    func resetContextTokenSnapshot() async
    func recordContextSnapshot(
        for conversationID: UUID,
        from response: LLMResponse,
        requestConfig: LLMRequestConfig
    ) async
    func acquireOrchestrator(
        conversationID: UUID,
        modelName: String,
        buildIfMissing: @escaping OrchestratorPoolBuildFactory
    ) async -> OrchestratorAcquisition?
    func releaseOrchestrator(_ handle: OrchestratorHandle) async
    func invalidateOrchestrator(for conversationID: UUID) async
}

protocol AgentRuntimeOrchestratorSessionAccessing: AgentRuntimeOrchestratorBinding, AgentRuntimeOrchestrationEmitting {
    func snapshotOrchestrationState(for conversationID: UUID) async -> ConversationOrchestrationState?
    func cancelAgenticOrchestrationSnapshotListeners() async
    func cancelAgenticOrchestrationSnapshotListeners(for conversationID: UUID) async
    func installAgenticOrchestrationSnapshotListeners(
        on listener: any OrchestratorListenerServicing,
        conversationID: UUID
    ) async
    func updateLifecycle(_ mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void) async
    func updateLifecycle(
        for conversationID: UUID,
        mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void
    ) async
    func startStreamingOrchestrationTask(
        sendingConversationID: UUID,
        turnLoopAnchorUserMessageID: UUID?,
        configuration: HarnessRuntimeSession.Configuration,
        orchestrator: SwiftAgentKitOrchestrator
    ) async
}

protocol AgentRuntimeOrchestrationEmitting: Sendable {
    func emitOrchestrationStateFromLiveSources(
        swiftAgentKitGeneration: UInt64?,
        preferredConversationID: UUID?
    ) async
    func streamingGenerationSettled(conversationID: UUID, runID: UUID?) async -> Bool
}

protocol AgentRuntimeRunControlling: Sendable {
    func cancelGeneration(for conversationID: UUID) async
    func cancelGeneration() async
    func cancelActiveRunForAPI(conversationID: UUID, runID: UUID) async throws
    func cancelSubAgentRun(conversationID: UUID, runID: UUID) async
    func listRunsForAPI(
        conversationID: UUID,
        filter: ConversationRunListFilter
    ) async -> ConversationRunListResponse
    func getRunForAPI(
        conversationID: UUID,
        runID: UUID,
        includeProjectionDetail: Bool
    ) async -> ConversationRunInfo?
}

protocol AgentRuntimeResidualStateReading: Sendable {
    func lastOrchestrationEmissionConversationID() async -> UUID?
}

protocol AgentRuntimeTokenSnapshotting: Sendable {
    @available(*, deprecated, message: "Use tokenSnapshotsForOrchestration(for:) with an explicit conversationID.")
    func tokenSnapshotsForOrchestration() async -> (lastPromptTokens: Int?, lastContextLimitTokens: Int?)
    func tokenSnapshotsForOrchestration(for conversationID: UUID) async -> (
        lastPromptTokens: Int?,
        lastContextLimitTokens: Int?
    )
}

protocol AgentRuntimeLaneErrorMapping: Sendable {
    func runtimeSessionError(
        for admissionError: RuntimeLaneAdmissionError,
        conversationID: UUID,
        fallbackRunID: UUID
    ) async -> ConversationServiceError
}

protocol AgentRuntimeStreamingServicing: Sendable {
    func serviceRuntimeMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]>
    func serviceRuntimeSendMessageAndStreamResponse(
        _ text: String,
        images: [Message.Image],
        conversationID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse
    func serviceRuntimeRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse
    func serviceRuntimeSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse
    func cancelMessageStreamForAPI() async
    func setOrchestrationStateOutOfBandPush(
        id: UUID,
        push: @escaping @Sendable (ConversationOrchestrationState) async -> Void
    ) async
    func clearOrchestrationStateOutOfBandPush(id: UUID) async
    func requestTurnLoopStop(conversationID: UUID) async
}

// MARK: - Sub-agent cycle

protocol SubAgentSpawnDelegating: Sendable {
    func applySubAgentDelegateEvent(_ event: SubAgentDelegateEvent) async
    func subAgentLifecyclePublisherConfigured() async -> Bool
    func conversationTopicPublisherConfigured() async -> Bool
}

protocol SubAgentSpawnLifecycleServicing: Sendable {
    func stopCompletionHandoffOwner() async
    func rebuildSubAgentLifecycleFromPersistedConversations() async
}

// MARK: - Tool data

protocol ConversationToolDataProviding: Sendable {
    func conversationToolData() async -> ConversationToolDataService
}

protocol SubAgentOrchestratorRuntimeServicing: OrchestratorRuntimeToolPolicyServicing {
    func setupOrchestrator(with selectedModel: Model, activeConversation preferredConversation: ModelConversation?) async
}
