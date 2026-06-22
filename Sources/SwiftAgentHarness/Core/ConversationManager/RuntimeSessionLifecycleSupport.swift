import CryptoKit
import EasyJSON
import Foundation
import SwiftAgentKit

extension HarnessRuntimeSession {

    internal static func messagesForTurnLoopHeuristics(_ messages: [Message], anchorUserMessageID: UUID?) -> [Message] {
        AgentRuntimeLoopHeuristics.messagesForHeuristics(messages, anchorUserMessageID: anchorUserMessageID)
    }

    internal static func hasRunawayEmptyAssistantStreak(_ messages: [Message]) -> Bool {
        AgentRuntimeLoopHeuristics.hasRunawayEmptyAssistantStreak(messages)
    }

    static func consecutiveChattyAssistantCount(atEndOf messages: [Message]) -> Int {
        AgentRuntimeLoopHeuristics.consecutiveChattyAssistantCount(atEndOf: messages)
    }

    internal static func maxRepeatToolCallStreak(in messages: [Message], threshold: Int) -> Bool {
        AgentRuntimeLoopHeuristics.maxRepeatToolCallStreak(in: messages, threshold: threshold)
    }

    internal func persistRunLifecycleTranscriptMarkerForTesting(
        conversationID: UUID,
        payload: RunLifecycleTranscriptMarkerPayload
    ) async throws {
        try await persistenceDomain.routingPersistRunLifecycleTranscriptMarker(conversationID: conversationID, payload: payload)
    }


    struct ToolPayloadProvenance: Sendable {
        let digest: String
        let byteCount: Int
        let redaction: String
        let truncated: Bool
    }

    struct RuntimeToolCorrelation: Sendable {
        let runID: UUID?
        let toolName: String?
        let toolCallID: String?
        let delegateHandleID: String?
        let completionAnnounceID: UUID?
    }

    struct ExecutionDispatchContext: Sendable {
        let executionEnvironmentKind: String
        let executionEnvironmentAdapterID: String
        let executionIsolationLevel: String
    }

    internal func executionDispatchContext(for entry: ToolRegistryEntry) -> ExecutionDispatchContext {
        ExecutionDispatchContext(
            executionEnvironmentKind: entry.executionEnvironment.kind.rawValue,
            executionEnvironmentAdapterID: entry.executionEnvironment.adapterID,
            executionIsolationLevel: entry.executionEnvironment.isolationLevel.rawValue
        )
    }

    static func toolPayloadProvenance(
        text: String,
        redaction: String = "digestOnly"
    ) -> ToolPayloadProvenance? {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolPayloadProvenance(
            digest: digest,
            byteCount: data.count,
            redaction: redaction,
            truncated: false
        )
    }

    static func toolPayloadProvenance(
        json: JSON,
        redaction: String = "digestOnly"
    ) -> ToolPayloadProvenance? {
        guard let encoded = try? JSONEncoder().encode(json), !encoded.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return ToolPayloadProvenance(
            digest: digest,
            byteCount: encoded.count,
            redaction: redaction,
            truncated: false
        )
    }

    internal func markStreamingGenerationCompleteIfCurrent(
        token: UInt64,
        terminalStatus: ConversationRunWireStatus? = nil,
        terminalReason: ConversationRunTerminalReason? = nil,
        markerKind: String? = nil,
        conversationID: UUID? = nil,
        runID: UUID? = nil
    ) async {
        await agentRuntimeSessionService.markStreamingGenerationCompleteIfCurrent(
            token: token,
            terminalStatus: terminalStatus,
            terminalReason: terminalReason,
            markerKind: markerKind,
            conversationID: conversationID,
            runID: runID
        )
    }

    internal func mostRecentConversation() async -> ModelConversation? {
        await persistenceDomain.mostRecentConversation()
    }

    internal func listConversationInfo() async -> [ModelConversation] {
        await persistenceDomain.listConversationInfo()
    }

    internal func evictRegistryForTesting() async {
        await persistenceDomain.evictRegistryForTesting()
    }

    public func budgetLedgerHydrationSeeds() async -> [BudgetLedgerHydrationSeed] {
        await conversationStartupService.budgetLedgerHydrationSeeds()
    }

    internal func persistConversationMetadataToCache(conversationID: UUID, metadata: JSON?) async throws {
        guard let metadata else { return }
        try await persistenceDomain.persistConversationMetadataToCache(conversationID: conversationID, metadata: metadata)
    }

    internal func stringMetadataValue(conversation: ModelConversation, key: String) -> String? {
        guard let metadata = conversation.metadata,
              case .object(let object) = metadata,
              let value = object[key] else { return nil }
        guard case .string(let text) = value else { return nil }
        return text
    }

    internal func stringArrayMetadataValue(conversation: ModelConversation, key: String) -> [String] {
        guard let metadata = conversation.metadata,
              case .object(let object) = metadata,
              let value = object[key] else { return [] }
        guard case .array(let array) = value else { return [] }
        return array.compactMap {
            guard case .string(let text) = $0 else { return nil }
            return text
        }
    }

    internal func modeSubAgentAllowListAllows(
        modeAllowList: [String]?,
        delegateToolName: String
    ) -> Bool {
        guard let modeAllowList else { return true }
        let normalized = Set(modeAllowList.map { $0.lowercased() })
        if normalized.contains("*") {
            return true
        }
        return normalized.contains(delegateToolName.lowercased())
    }

    public func conversationWireCurrentRunID(conversationID: UUID) async -> UUID {
        await conversationStartupService.conversationWireCurrentRunID(conversationID: conversationID)
    }
}
