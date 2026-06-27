import Foundation
import SwiftAgentKit

/// Runtime-owned APILayer streaming boundary wired to agent runtime and replay services.
public final class RuntimeStreamingOrchestrationService: APILayerChatRuntimeManaging, Sendable {
    private let agentRuntime: any AgentRuntimeStreamingServicing & AgentRuntimeRunControlling
    private let conversationReplay: ConversationReplayService

    public convenience init(
        agentRuntimeSessionService: AgentRuntimeSessionService,
        conversationReplay: ConversationReplayService
    ) {
        self.init(
            agentRuntime: agentRuntimeSessionService,
            conversationReplay: conversationReplay
        )
    }

    init(
        agentRuntime: any AgentRuntimeStreamingServicing & AgentRuntimeRunControlling,
        conversationReplay: ConversationReplayService
    ) {
        self.agentRuntime = agentRuntime
        self.conversationReplay = conversationReplay
    }

    public func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        try await agentRuntime.serviceRuntimeMessageStream(for: conversationID)
    }

    public func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        systemReminder: String?,
        originSurface: String? = nil,
        originSenderID: String? = nil
    ) async throws -> ChatStreamResponse {
        let harness = AgentHarnessConfiguration.loadFromPromptConfigBundle()
        let base = AgentRuntimeTurnConfiguration(
            enableTools: enableTools,
            enableAgents: enableAgents,
            expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
            inputTrustRaw: inputTrustRaw,
            ephemeralSystemReminder: systemReminder
        )
        let configuration: AgentRuntimeTurnConfiguration
        if let originSurface, !originSurface.isEmpty {
            configuration = MessageOutputTurnConfiguration.forInteractiveSend(
                base: base,
                originSurface: originSurface,
                originSenderID: originSenderID ?? "*",
                harness: harness
            )
        } else {
            configuration = MessageOutputTurnConfiguration.forCLISend(
                base: base,
                originSenderID: originSenderID,
                harness: harness
            )
        }
        return try await agentRuntime.serviceRuntimeSendMessageAndStreamResponse(
            text,
            images: images,
            conversationID: conversationID,
            configuration: configuration
        )
    }

    public func apiRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        try await agentRuntime.serviceRuntimeRevertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: messageID,
            configuration: MessageOutputTurnConfiguration.forInteractiveSend(
                base: AgentRuntimeTurnConfiguration(enableTools: enableTools, enableAgents: enableAgents),
                originSurface: InteractiveSurfaceID.rest
            )
        )
    }

    public func apiSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        try await agentRuntime.serviceRuntimeSplitConversationAtUserMessage(
            conversationID: conversationID,
            messageID: messageID,
            configuration: MessageOutputTurnConfiguration.forInteractiveSend(
                base: AgentRuntimeTurnConfiguration(enableTools: enableTools, enableAgents: enableAgents),
                originSurface: InteractiveSurfaceID.rest
            )
        )
    }

    public func apiCancelMessageStream() async {
        await agentRuntime.cancelMessageStreamForAPI()
    }

    public func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async {
        await agentRuntime.setOrchestrationStateOutOfBandPush(id: id, push: push)
    }

    public func apiClearOrchestrationStateOutOfBandPush(id: UUID) async {
        await agentRuntime.clearOrchestrationStateOutOfBandPush(id: id)
    }

    public func apiStartConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws {
        try await conversationReplay.serviceRuntimeStartConversationReplay(
            sourceConversationID: conversationID,
            configuration: .init(enableTools: enableTools, enableAgents: enableAgents)
        )
    }

    public func apiStopConversationReplay(conversationID: UUID) async {
        await conversationReplay.stopConversationReplay(conversationID: conversationID)
    }

    public func apiIsConversationReplayActive(conversationID: UUID) async -> Bool {
        await conversationReplay.isConversationReplayActive(conversationID: conversationID)
    }

    public func apiRequestTurnLoopStop(conversationID: UUID) async {
        await agentRuntime.requestTurnLoopStop(conversationID: conversationID)
    }

    public func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        try await agentRuntime.cancelActiveRunForAPI(conversationID: conversationID, runID: runID)
    }

    public func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        await agentRuntime.listRunsForAPI(conversationID: conversationID, filter: filter)
    }

    public func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        await agentRuntime.getRunForAPI(
            conversationID: conversationID,
            runID: runID,
            includeProjectionDetail: includeProjectionDetail
        )
    }
}
