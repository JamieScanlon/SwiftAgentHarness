import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

private actor CompletionAnnounceEventRecorder: ConversationTopicPublishing {
    private var payloads: [ConversationTopicEventPayload] = []

    func publishPersistedConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        transcriptSequence: Int
    ) async {
        let _ = conversationID
        let _ = transcriptSequence
        payloads.append(payload)
    }

    func publishTransientConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        runID: UUID,
        modelCallId: UUID?
    ) async {
        let _ = conversationID
        let _ = runID
        let _ = modelCallId
        payloads.append(payload)
    }

    func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async {
        let _ = conversationID
        payloads.append(payload)
    }

    func runtimeLifecycleEvents() -> [RuntimeLifecycleEventPayload] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return payloads.compactMap { payload in
            guard payload.semanticKind == .runtimeLifecycle,
                  let json = payload.jsonUTF8,
                  let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(RuntimeLifecycleEventPayload.self, from: data)
        }
    }
}

@Suite("Completion announce pipeline", .serialized)
struct CompletionAnnouncePipelineTests {
    private func waitForCompletionAnnounce(
        recorder: CompletionAnnounceEventRecorder,
        delegateHandleID: String,
        toolCallID: String,
        timeoutMS: Int = 2_000
    ) async -> RuntimeLifecycleEventPayload? {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000.0)
        while Date() < deadline {
            let events = await recorder.runtimeLifecycleEvents()
            if let announce = events.last(where: {
                $0.name == .toolCompletionAnnounced &&
                    $0.delegateHandleID == delegateHandleID &&
                    $0.toolCallID == toolCallID
            }) {
                return announce
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test("duplicate completion announce is idempotent by handle and toolCall")
    func duplicateCompletionAnnounceSuppressed() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "announce-test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        try await manager.createConversation(with: model, userSystemPrompt: "announce-idempotency")
        let conversationID = try #require(await manager.currentConversationID)
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "handle-dup",
            toolCallID: "tool-dup",
            conversationID: conversationID,
            parentConversationID: nil,
            lifecycleID: "handle-dup",
            status: .done,
            completedAt: Date(),
            source: "test.duplicate"
        )
        await manager.ingestCompletionAnnouncementForAPI(payload, toolMessageContent: "done once")
        await manager.ingestCompletionAnnouncementForAPI(payload, toolMessageContent: "done once")
        let updated = await await makeSplitConversationAdapter(runtimeSession: manager).apiGetConversation(id: conversationID)
        let toolMessages = updated?.messages.filter { $0.role == .tool && $0.toolCallId == "tool-dup" } ?? []
        #expect(toolMessages.count == 1)
    }

    @Test("pending completion announce replays after reset when publisher is attached")
    func replayPendingCompletionAnnouncementAfterReset() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "announce-replay-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        try await manager.createConversation(with: model, userSystemPrompt: "announce-replay")
        let conversationID = try #require(await manager.currentConversationID)
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "handle-replay",
            toolCallID: "tool-replay",
            conversationID: conversationID,
            parentConversationID: nil,
            lifecycleID: "handle-replay",
            status: .done,
            completedAt: Date(),
            source: "test.replay",
            usage: DelegateCompletionUsagePayload(promptTokens: 10, completionTokens: 5, totalTokens: 15, costUSD: 0.0125)
        )
        await manager.ingestCompletionAnnouncementForAPI(payload, toolMessageContent: "queued pending")
        try await manager.resetConversationsFromCatalog(availableModels: [model])
        let recorder = CompletionAnnounceEventRecorder()
        await manager.setConversationTopicPublisher(recorder)
        await manager.subAgentCompletionRuntimeService.retryPendingCompletionAnnouncements()
        let announce = await waitForCompletionAnnounce(
            recorder: recorder,
            delegateHandleID: "handle-replay",
            toolCallID: "tool-replay"
        )
        #expect(announce?.toolCallID == "tool-replay")
        #expect(announce?.delegateHandleID == "handle-replay")
        #expect(announce?.usage?.totalTokens == 15)
        #expect(announce?.usage?.costUSD == 0.0125)
    }

    @Test("runtime lifecycle fanout persists derived audit without topic publisher")
    func runtimeLifecycleFanoutPersistsDerivedAuditWithoutTopicPublisher() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "announce-audit-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        try await manager.createConversation(with: model, userSystemPrompt: "announce-audit")
        let conversationID = try #require(await manager.currentConversationID)
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCallCompleted,
            conversationID: conversationID,
            runID: UUID(),
            iteration: 1,
            modelID: model.id,
            toolName: "filesystem_write",
            toolCallID: "tool-audit",
            source: "test.audit"
        )
        await manager.runtimeLifecyclePublicationService.publishRuntimeLifecycleWithFanout(payload)

        let kind = ConversationEventKind.toolAuditLifecycleEvent.rawValue
        let decoded = await HarnessConversationTestFixtures.journalEvents(
            host: manager,
            conversationID: conversationID,
            kind: kind
        ).compactMap {
            ConversationEventCodec.decode(ToolAuditLifecycleEventPayload.self, from: $0.payloadJSON)
        }
        #expect(decoded.contains {
            $0.name == .toolCallCompleted
                && $0.toolCallID == "tool-audit"
        })
    }

    @Test("pending completion announce preserves correlation parity across topic trace and derived audit")
    func pendingCompletionAnnounceParityAcrossFanoutSinks() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let recorder = CompletionAnnounceEventRecorder()
        await manager.setConversationTopicPublisher(recorder)
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "announce-parity-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        try await manager.createConversation(with: model, userSystemPrompt: "announce-parity")
        let conversationID = try #require(await manager.currentConversationID)
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "handle-parity",
            toolCallID: "tool-parity",
            conversationID: conversationID,
            parentConversationID: nil,
            lifecycleID: "handle-parity",
            status: .done,
            completedAt: Date(),
            source: "test.parity",
            usage: DelegateCompletionUsagePayload(promptTokens: 30, completionTokens: 12, totalTokens: 42, costUSD: 0.0315)
        )

        await manager.ingestCompletionAnnouncementForAPI(payload, toolMessageContent: "done")

        let topicAnnounce = try #require(await waitForCompletionAnnounce(
            recorder: recorder,
            delegateHandleID: "handle-parity",
            toolCallID: "tool-parity"
        ))
        let trace = await manager.traceSnapshotForConversationAPI(conversationID: conversationID)
        let traceAnnounce = try #require(trace.spans.last(where: {
            $0.name == RuntimeLifecycleEventName.toolCompletionAnnounced.rawValue
                && $0.attributes?["toolCallID"] == "tool-parity"
        }))

        let kind = ConversationEventKind.toolAuditLifecycleEvent.rawValue
        let audits = await HarnessConversationTestFixtures.journalEvents(
            host: manager,
            conversationID: conversationID,
            kind: kind
        ).compactMap {
            ConversationEventCodec.decode(ToolAuditLifecycleEventPayload.self, from: $0.payloadJSON)
        }
        let matchingAudits = audits.filter {
            $0.name == .toolCompletionAnnounced && $0.toolCallID == "tool-parity"
        }
        let auditAnnounce = try #require(matchingAudits.first)

        #expect(topicAnnounce.toolCallID == auditAnnounce.toolCallID)
        #expect(topicAnnounce.toolCallID == traceAnnounce.attributes?["toolCallID"])
        #expect(topicAnnounce.delegateHandleID == auditAnnounce.delegateHandleID)
        #expect(topicAnnounce.delegateHandleID == traceAnnounce.attributes?["delegateHandleID"])
        #expect(topicAnnounce.completionAnnounceID == auditAnnounce.completionAnnounceID)
        #expect(
            topicAnnounce.completionAnnounceID?.uuidString.lowercased()
                == traceAnnounce.attributes?["completionAnnounceID"]
        )
        #expect(topicAnnounce.toolName == auditAnnounce.toolName)
        #expect(topicAnnounce.toolName == traceAnnounce.attributes?["toolName"])
        #expect(topicAnnounce.usage?.totalTokens == auditAnnounce.usage?.totalTokens)
        #expect(topicAnnounce.usage?.costUSD == auditAnnounce.usage?.costUSD)
        #expect(traceAnnounce.attributes?["usage.totalTokens"] == "42")
        #expect(traceAnnounce.attributes?["usage.costUSD"] == "0.031500")
    }

}
