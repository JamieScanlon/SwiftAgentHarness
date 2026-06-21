import Foundation
import SwiftAgentKit

/// Runtime-owned APILayer streaming boundary wired to agent runtime and replay services.
final class RuntimeStreamingOrchestrationService: APILayerChatRuntimeManaging, Sendable {
    private let agentRuntime: any AgentRuntimeStreamingServicing & AgentRuntimeRunControlling
    private let conversationReplay: ConversationReplayService

    init(
        agentRuntime: any AgentRuntimeStreamingServicing & AgentRuntimeRunControlling,
        conversationReplay: ConversationReplayService
    ) {
        self.agentRuntime = agentRuntime
        self.conversationReplay = conversationReplay
    }

    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        try await agentRuntime.serviceRuntimeMessageStream(for: conversationID)
    }

    func apiSendMessageAndStreamResponse(
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
        try await agentRuntime.serviceRuntimeSendMessageAndStreamResponse(
            text,
            images: images,
            conversationID: conversationID,
            configuration: .init(
                enableTools: enableTools,
                enableAgents: enableAgents,
                expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
                inputTrustRaw: inputTrustRaw,
                ephemeralSystemReminder: systemReminder,
                originSurface: originSurface ?? "cli",
                originSenderID: originSenderID ?? "*"
            )
        )
    }

    func apiRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        try await agentRuntime.serviceRuntimeRevertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: messageID,
            configuration: .init(enableTools: enableTools, enableAgents: enableAgents)
        )
    }

    func apiSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        try await agentRuntime.serviceRuntimeSplitConversationAtUserMessage(
            conversationID: conversationID,
            messageID: messageID,
            configuration: .init(enableTools: enableTools, enableAgents: enableAgents)
        )
    }

    func apiCancelMessageStream() async {
        await agentRuntime.cancelMessageStreamForAPI()
    }

    func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async {
        await agentRuntime.setOrchestrationStateOutOfBandPush(id: id, push: push)
    }

    func apiClearOrchestrationStateOutOfBandPush(id: UUID) async {
        await agentRuntime.clearOrchestrationStateOutOfBandPush(id: id)
    }

    func apiStartConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws {
        try await conversationReplay.serviceRuntimeStartConversationReplay(
            sourceConversationID: conversationID,
            configuration: .init(enableTools: enableTools, enableAgents: enableAgents)
        )
    }

    func apiStopConversationReplay(conversationID: UUID) async {
        await conversationReplay.stopConversationReplay(conversationID: conversationID)
    }

    func apiIsConversationReplayActive(conversationID: UUID) async -> Bool {
        await conversationReplay.isConversationReplayActive(conversationID: conversationID)
    }

    func apiRequestTurnLoopStop(conversationID: UUID) async {
        await agentRuntime.requestTurnLoopStop(conversationID: conversationID)
    }

    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        try await agentRuntime.cancelActiveRunForAPI(conversationID: conversationID, runID: runID)
    }

    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        await agentRuntime.listRunsForAPI(conversationID: conversationID, filter: filter)
    }

    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        await agentRuntime.getRunForAPI(
            conversationID: conversationID,
            runID: runID,
            includeProjectionDetail: includeProjectionDetail
        )
    }
}
