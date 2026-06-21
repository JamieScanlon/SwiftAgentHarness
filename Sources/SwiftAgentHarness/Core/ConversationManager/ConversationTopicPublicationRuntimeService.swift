import Foundation

/// Conversation-topic wire publication for checkpoint and message refresh events.
actor ConversationTopicPublicationRuntimeService {
    private let deps: ConversationRuntimeDependencies
    private let agentRuntime: any AgentRuntimeOrchestratorBinding
    private let startup: ConversationStartupService

    init(
        deps: ConversationRuntimeDependencies,
        agentRuntime: any AgentRuntimeOrchestratorBinding,
        startup: ConversationStartupService
    ) {
        self.deps = deps
        self.agentRuntime = agentRuntime
        self.startup = startup
    }

    func publishConversationTopicEventIfConfigured(
        conversationID: UUID,
        payload: ConversationTopicEventPayload
    ) async {
        guard let publisher = await startup.conversationTopicPublisherForRuntime() else { return }
        let lifecycle = await agentRuntime.lifecycleSnapshot(for: conversationID)
        let runID =
            await deps.persistenceDomain.modelConversation(id: conversationID)?.currentRunID
                ?? lifecycle.currentStreamingRunID
        let payloadSizeBytes = payload.jsonUTF8?.utf8.count ?? 0
        deps.logger?.debug(
            "[ConversationTopicPublicationRuntimeService] conversation-topic publish requested conversationID=\(conversationID.uuidString) semanticKind=\(payload.semanticKind.rawValue) runID=\(runID?.uuidString ?? "nil") payloadBytes=\(payloadSizeBytes)"
        )
        switch ConversationEventsReplayClassifier.stream(for: payload) {
        case .transient:
            let rid = runID ?? UUID()
            await publisher.publishTransientConversationEvent(
                conversationID: conversationID,
                payload: payload,
                runID: rid,
                modelCallId: nil
            )
        case .persistedMessage, .persistedCheckpoint:
            if let seq = try? await deps.persistenceDomain.latestTranscriptSequence(
                conversationID: conversationID
            ) {
                await publisher.publishPersistedConversationEvent(
                    conversationID: conversationID,
                    payload: payload,
                    transcriptSequence: seq
                )
            } else {
                await publisher.publishConversationEvent(conversationID: conversationID, payload: payload)
            }
        }
    }

    func publishContextCompactionCheckpointTopic(spec: ContextCompactionCheckpointPersistenceSpec) async {
        let wire = ConversationCheckpointTopicEventWire(
            variant: .contextCompactionCheckpoint,
            conversationID: spec.conversationID,
            harnessCheckpointKind: HarnessCheckpointWireKind.contextCompaction.rawValue,
            compactionCheckpointKind: spec.kind.rawValue,
            coveredRawMessageIDs: spec.rawMiddleMessageIDs,
            basedOnTailMessageID: spec.rawMiddleMessageIDs.last,
            invalidatedCheckpointKinds: nil
        )
        let payload = ConversationTopicWireEncoding.checkpointTopicPayload(wire: wire)
        await publishConversationTopicEventIfConfigured(conversationID: spec.conversationID, payload: payload)
    }

    func publishCheckpointInvalidationOnTopic(conversationID: UUID, invalidatedKinds: [String]) async {
        let wire = ConversationCheckpointTopicEventWire(
            variant: .checkpointInvalidation,
            conversationID: conversationID,
            harnessCheckpointKind: nil,
            compactionCheckpointKind: nil,
            coveredRawMessageIDs: nil,
            basedOnTailMessageID: nil,
            invalidatedCheckpointKinds: invalidatedKinds
        )
        let payload = ConversationTopicWireEncoding.checkpointTopicPayload(wire: wire)
        await publishConversationTopicEventIfConfigured(conversationID: conversationID, payload: payload)
    }
}
