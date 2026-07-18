#if canImport(Darwin)
import Darwin
#endif
import Foundation
import SwiftAgentKit
import SwiftData
import Testing
import VaporTesting

@testable import SwiftAgentHarness

private actor RunDurabilityEventRecorder: ConversationTopicPublishing {
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

private final class RunLifecycleStubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]

    init(models: [Model]) {
        self.models = models
    }

    func getAvailableModels() async -> [Model] {
        models
    }
}

private enum RunLifecycleDurabilityTestSupport {
    static func enableV2Bootstrap() {
    }

    static func makeContainer() throws -> ModelContainer {
        enableV2Bootstrap()
                return try HarnessTestModelContainer.makeInMemory()
    }

    static func makeTestModel(id: UUID = UUID()) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "run-durable-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func messageEntry(
        _ message: Message,
        sequence: Int,
        transcriptRunID: UUID?,
        finishReason: String? = nil
    ) throws -> SessionTranscriptEntry {
        try SessionTranscriptMapping.entry(
            from: message,
            sequence: sequence,
            parentEntryId: nil,
            transcriptRunID: transcriptRunID,
            finishReason: finishReason
        )
    }

    static func runtimeAPI(_ runtimeSession: HarnessRuntimeSession) async -> RuntimeStreamingOrchestrationService {
        RuntimeStreamingOrchestrationService(
            agentRuntime: await runtimeSession.agentRuntimeSessionService,
            conversationReplay: await runtimeSession.conversationReplayService
        )
    }
}

@Suite("Run lifecycle durability", .serialized)
struct RunLifecycleDurabilityTests {
    @Test("Projected runs survive restart with durable orphan reconciliation")
    func projectedRunsSurviveRestart() async throws {
        let container = try RunLifecycleDurabilityTestSupport.makeContainer()
        let model = RunLifecycleDurabilityTestSupport.makeTestModel()
        let mem = InMemoryHarnessSessionPersistence()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: mem)
        let managerRuntimeAPI = await RunLifecycleDurabilityTestSupport.runtimeAPI(manager)
        try await manager.createConversation(with: model, userSystemPrompt: "durable runs")
        let conversationID = try #require(await manager.currentConversationID)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let completedRunID = UUID()
        let staleRunningRunID = UUID()

        let userDone = Message(
            id: UUID(),
            role: .user,
            content: "run-a",
            timestamp: base,
            images: [],
            toolCalls: [],
            toolCallId: nil,
            inputTrustRaw: "user"
        )
        let asstDone = Message(
            id: UUID(),
            role: .assistant,
            content: "reply-a",
            timestamp: base.addingTimeInterval(5),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            inputTrustRaw: nil
        )
        let userStale = Message(
            id: UUID(),
            role: .user,
            content: "run-b",
            timestamp: base.addingTimeInterval(10),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            inputTrustRaw: "user"
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(userDone, sequence: 1, transcriptRunID: completedRunID)
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(
                asstDone,
                sequence: 2,
                transcriptRunID: completedRunID,
                finishReason: "stop"
            )
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(userStale, sequence: 3, transcriptRunID: staleRunningRunID)
        )

        let beforeRestart = await managerRuntimeAPI.apiListConversationRuns(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 50)
        ).runs
        #expect(beforeRestart.count == 2)
        #expect(beforeRestart[0].id == staleRunningRunID)
        #expect(beforeRestart[0].outcome == .errored)
        #expect(beforeRestart[0].errorDetails?.class == "run_orphaned")
        #expect(beforeRestart[1].id == completedRunID)
        #expect(beforeRestart[1].outcome == .completed)

        let reloaded = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: mem)
        let reloadedRuntimeAPI = await RunLifecycleDurabilityTestSupport.runtimeAPI(reloaded)
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let afterRestart = await reloadedRuntimeAPI.apiListConversationRuns(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 50)
        ).runs
        #expect(afterRestart.count == 2)
        #expect(afterRestart[0].id == staleRunningRunID)
        #expect(afterRestart[0].outcome == .errored)
        #expect(afterRestart[0].errorDetails?.class == "run_orphaned")
        #expect(afterRestart[0].errorDetails?.message == "stale_running_reconciled")
        #expect(afterRestart[1].id == completedRunID)
        #expect(afterRestart[1].outcome == .completed)
        let one = await reloadedRuntimeAPI.apiGetConversationRun(conversationID: conversationID, runID: completedRunID)
        #expect(one?.outcome == .completed)

        let reloadedAgain = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: mem)
        let reloadedAgainRuntimeAPI = await RunLifecycleDurabilityTestSupport.runtimeAPI(reloadedAgain)
        try await reloadedAgain.resetConversationsFromCatalog(availableModels: [model])
        let afterSecondRestart = await reloadedAgainRuntimeAPI.apiListConversationRuns(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 50)
        ).runs
        #expect(afterSecondRestart.count == 2)
        #expect(afterSecondRestart[0].id == staleRunningRunID)
        #expect(afterSecondRestart[0].outcome == .errored)
        #expect(afterSecondRestart[0].errorDetails?.class == "run_orphaned")
    }

    @Test("REST /runs and /runs/:runId use projection-backed durable history after restart")
    func restRunsSurviveRestart() async throws {
        let container = try RunLifecycleDurabilityTestSupport.makeContainer()
        let model = RunLifecycleDurabilityTestSupport.makeTestModel()
        let mem = InMemoryHarnessSessionPersistence()
        let writer = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: mem)
        try await writer.createConversation(with: model, userSystemPrompt: "durable rest runs")
        let conversationID = try #require(await writer.currentConversationID)
        let runID = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        let userMsg = Message(
            id: UUID(),
            role: .user,
            content: "hi",
            timestamp: at,
            images: [],
            toolCalls: [],
            toolCallId: nil,
            inputTrustRaw: "user"
        )
        let asstMsg = Message(
            id: UUID(),
            role: .assistant,
            content: "bye",
            timestamp: at.addingTimeInterval(2),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            inputTrustRaw: nil
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(userMsg, sequence: 1, transcriptRunID: runID)
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(
                asstMsg,
                sequence: 2,
                transcriptRunID: runID,
                finishReason: "stop"
            )
        )
        await writer.runtimeLifecyclePublicationService.consumeRuntimeLifecycleEventForDerivedAudit(
            RuntimeLifecycleEventPayload(
                name: .toolCompletionAnnounced,
                conversationID: conversationID,
                runID: runID,
                iteration: 1,
                modelID: model.id,
                toolName: "web_search",
                toolCallID: "tool-rollup-1",
                completionAnnounceID: UUID(),
                usage: DelegateCompletionUsagePayload(
                    promptTokens: 21,
                    completionTokens: 9,
                    totalTokens: 30,
                    costUSD: 0.045
                ),
                source: "runtime.rollup.test"
            )
        )

        let api = APILayer(port: 0)
        let reader = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: mem)
        try await reader.resetConversationsFromCatalog(availableModels: [model])
        let modelProvider = RunLifecycleStubModelProvider(models: [model])
        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: reader, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs?limit=1") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let runs = body?["runs"] as? [[String: Any]]
                #expect(runs?.count == 1)
                #expect(runs?.first?["id"] as? String == runID.uuidString)
                #expect(runs?.first?["outcome"] as? String == ConversationRunOutcome.completed.rawValue)
                #expect(runs?.first?["status"] == nil)
                #expect(runs?.first?["terminalReason"] == nil)
                #expect(runs?.first?["markerKind"] == nil)
                #expect(runs?.first?["iterationCount"] as? Int == 1)
                #expect(runs?.first?["toolCallCount"] as? Int == 0)
                #expect((runs?.first?["firstMessageId"] as? String)?.isEmpty == false)
                #expect((runs?.first?["lastMessageId"] as? String)?.isEmpty == false)
                let tokens = runs?.first?["tokenRollup"] as? [String: Any]
                let cost = runs?.first?["costRollup"] as? [String: Any]
                #expect(tokens?["promptTokens"] as? Int == 21)
                #expect(tokens?["completionTokens"] as? Int == 9)
                #expect(tokens?["totalTokens"] as? Int == 30)
                #expect(cost?["usd"] as? Double == 0.045)
            }
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["id"] as? String == runID.uuidString)
                #expect(body?["outcome"] as? String == ConversationRunOutcome.completed.rawValue)
                #expect(body?["status"] == nil)
                let tokens = body?["tokenRollup"] as? [String: Any]
                let cost = body?["costRollup"] as? [String: Any]
                #expect(tokens?["promptTokens"] as? Int == 21)
                #expect(tokens?["completionTokens"] as? Int == 9)
                #expect(tokens?["totalTokens"] as? Int == 30)
                #expect(cost?["usd"] as? Double == 0.045)
            }
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs/\(runID.uuidString)?detail=1") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["id"] as? String == runID.uuidString)
                let detail = body?["projectionDetail"] as? [String: Any]
                #expect(detail != nil)
                #expect(detail?["assistantMessageCount"] as? Int == 1)
                #expect(detail?["toolRollup"] == nil)
            }
        }
    }

    @Test("Projected cancelled runs retain terminal reason and marker")
    func projectedCancelledRunReasonAndMarker() async throws {
        let container = try RunLifecycleDurabilityTestSupport.makeContainer()
        let model = RunLifecycleDurabilityTestSupport.makeTestModel()
        let mem = InMemoryHarnessSessionPersistence()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: mem)
        let runtimeAPI = await RunLifecycleDurabilityTestSupport.runtimeAPI(manager)
        try await manager.createConversation(with: model, userSystemPrompt: "cancel reason")
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_200)

        let userMsg = Message(
            id: UUID(),
            role: .user,
            content: "stop later",
            timestamp: at,
            images: [],
            toolCalls: [],
            toolCallId: nil,
            inputTrustRaw: "user"
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(userMsg, sequence: 1, transcriptRunID: runID)
        )
        try await manager.persistRunLifecycleTranscriptMarkerForTesting(
            conversationID: conversationID,
            payload: RunLifecycleTranscriptMarkerPayload(
                kind: .run_cancelled,
                runId: runID,
                createdAt: at.addingTimeInterval(1),
                terminalReason: ConversationRunTerminalReason(
                    category: .externalCancellation,
                    detail: "user_stop_requested"
                )
            )
        )

        let rows = await runtimeAPI.apiListConversationRuns(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 10)
        ).runs
        let row = try #require(rows.first(where: { $0.id == runID }))
        #expect(row.outcome == .cancelled)
        #expect(row.cancellationReason == "user_stop_requested")
    }

    @Test("REST /runs supports kinds/outcomes/since/cursor and 304 cache validation")
    func restRunsFilterCursorAndCacheSemantics() async throws {
        let container = try RunLifecycleDurabilityTestSupport.makeContainer()
        let model = RunLifecycleDurabilityTestSupport.makeTestModel()
        let mem = InMemoryHarnessSessionPersistence()
        let writer = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: mem)
        try await writer.createConversation(with: model, userSystemPrompt: "runs-filtering")
        let conversationID = try #require(await writer.currentConversationID)
        let runA = UUID()
        let runB = UUID()
        let base = Date(timeIntervalSince1970: 1_700_500_000)
        let userA = Message(
            id: UUID(), role: .user, content: "live", timestamp: base, images: [], toolCalls: [], toolCallId: nil, inputTrustRaw: "user"
        )
        let asstA = Message(
            id: UUID(), role: .assistant, content: "done", timestamp: base.addingTimeInterval(1), images: [], toolCalls: [], toolCallId: nil, inputTrustRaw: nil
        )
        let userB = Message(
            id: UUID(), role: .user, content: "trigger", timestamp: base.addingTimeInterval(10), images: [], toolCalls: [], toolCallId: nil, inputTrustRaw: "trigger"
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(userA, sequence: 1, transcriptRunID: runA)
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(
                asstA,
                sequence: 2,
                transcriptRunID: runA,
                finishReason: "stop"
            )
        )
        try mem.appendTranscriptEntry(
            conversationID: conversationID,
            entry: try RunLifecycleDurabilityTestSupport.messageEntry(userB, sequence: 3, transcriptRunID: runB)
        )
        try await writer.persistRunLifecycleTranscriptMarkerForTesting(
            conversationID: conversationID,
            payload: RunLifecycleTranscriptMarkerPayload(
                kind: .run_cancelled,
                runId: runB,
                reason: "user_stop_requested",
                createdAt: base.addingTimeInterval(11)
            )
        )

        let api = APILayer(port: 0)
        let reader = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: mem)
        try await reader.resetConversationsFromCatalog(availableModels: [model])
        let modelProvider = RunLifecycleStubModelProvider(models: [model])
        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: reader, modelProvider: modelProvider)

            var etag: String?
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs?limit=1") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == "no-cache")
                etag = res.headers.first(name: .eTag)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let runs = payload?["runs"] as? [[String: Any]]
                #expect(runs?.count == 1)
                #expect(payload?["cursor"] is String)
                #expect(payload?["total"] as? Int == 2)
            }

            let listETag = try #require(etag)
            #expect(listETag.hasPrefix("\"reg-"))
            try await app.testing().test(
                .GET,
                "/api/conversations/\(conversationID.uuidString)/runs?limit=1",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifNoneMatch, value: listETag)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notModified)
                    #expect(res.headers.first(name: .eTag) == listETag)
                    #expect(res.headers.first(name: .cacheControl) == "no-cache")
                }
            )

            var cursor: String?
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs?limit=1") { res async throws in
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cursor = payload?["cursor"] as? String
            }
            let nextCursor = try #require(cursor)
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs?limit=1&cursor=\(nextCursor)") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let runs = payload?["runs"] as? [[String: Any]]
                #expect(runs?.count == 1)
            }

            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs?kinds=trigger&outcomes=cancelled&limit=10") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let runs = payload?["runs"] as? [[String: Any]]
                #expect(runs?.count == 1)
                #expect(runs?.first?["id"] as? String == runB.uuidString)
            }

            let sinceMillis = Int((base.addingTimeInterval(5).timeIntervalSince1970 * 1000.0).rounded())
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs?since=\(sinceMillis)&limit=10") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let runs = payload?["runs"] as? [[String: Any]]
                #expect(runs?.count == 1)
                #expect(runs?.first?["id"] as? String == runB.uuidString)
            }

            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/runs?cursor=not-base64") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("runtime lifecycle approval audit events persist as derived projection rows")
    func runtimeLifecycleApprovalAuditPersistsAsDerivedEvent() async throws {
        let container = try RunLifecycleDurabilityTestSupport.makeContainer()
        let model = RunLifecycleDurabilityTestSupport.makeTestModel()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await manager.createConversation(with: model, userSystemPrompt: "audit")
        let conversationID = try #require(await manager.currentConversationID)
        let payload = RuntimeLifecycleEventPayload(
            name: .toolApprovalResolved,
            conversationID: conversationID,
            runID: UUID(),
            iteration: 1,
            modelID: model.id,
            toolName: "filesystem_write",
            approvalState: .approved,
            policyReason: "approvalRequired",
            approvalSource: "human.ui",
            approvalReason: "approved for test",
            approvalRoute: .user,
            source: "runtime.toolPolicy"
        )
        await manager.runtimeLifecyclePublicationService.consumeRuntimeLifecycleEventForDerivedAudit(payload)

        let kind = ConversationEventKind.toolAuditLifecycleEvent.rawValue
        let row = try #require(
            await HarnessConversationTestFixtures.journalEvents(
                host: manager,
                conversationID: conversationID,
                kind: kind
            ).last
        )
        let decoded = try #require(
            ConversationEventCodec.decode(ToolAuditLifecycleEventPayload.self, from: row.payloadJSON)
        )
        #expect(decoded.name == .toolApprovalResolved)
        #expect(decoded.toolName == "filesystem_write")
        #expect(decoded.approvalState == .approved)
        #expect(decoded.approvalSource == "human.ui")
    }

    @Test("runtime lifecycle tool usage summary events persist as derived projection rows")
    func runtimeLifecycleToolUsageSummaryPersistsAsDerivedEvent() async throws {
        let container = try RunLifecycleDurabilityTestSupport.makeContainer()
        let model = RunLifecycleDurabilityTestSupport.makeTestModel()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await manager.createConversation(with: model, userSystemPrompt: "summary audit")
        let conversationID = try #require(await manager.currentConversationID)
        let payload = RuntimeLifecycleEventPayload(
            name: .toolUsageSummary,
            conversationID: conversationID,
            runID: UUID(),
            toolCount: 4,
            toolNames: ["web_search", "web_fetch"],
            summaryText: "Ran web_search ×2, web_fetch ×2",
            source: "runtime.templateLabel"
        )
        await manager.runtimeLifecyclePublicationService.consumeRuntimeLifecycleEventForDerivedAudit(payload)

        let kind = ConversationEventKind.toolUsageSummaryEvent.rawValue
        let row = try #require(
            await HarnessConversationTestFixtures.journalEvents(
                host: manager,
                conversationID: conversationID,
                kind: kind
            ).last
        )
        let decoded = try #require(
            ConversationEventCodec.decode(ToolUsageSummaryEventPayload.self, from: row.payloadJSON)
        )
        #expect(decoded.toolCount == 4)
        #expect(decoded.toolNames == ["web_search", "web_fetch"])
        #expect(decoded.summaryText == "Ran web_search ×2, web_fetch ×2")
        #expect(decoded.source == "runtime.templateLabel")
    }

    @Test("runtime lifecycle model path preserves parity across topic trace and derived audit")
    func runtimeLifecycleModelPathFanoutParity() async throws {
        let container = try RunLifecycleDurabilityTestSupport.makeContainer()
        let model = RunLifecycleDurabilityTestSupport.makeTestModel()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let recorder = RunDurabilityEventRecorder()
        await manager.setConversationTopicPublisher(recorder)
        try await manager.createConversation(with: model, userSystemPrompt: "model-parity")
        let conversationID = try #require(await manager.currentConversationID)
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCallCompleted,
            conversationID: conversationID,
            runID: UUID(),
            iteration: 1,
            modelID: model.id,
            toolName: "filesystem_write",
            toolCallID: "tool-model-parity",
            argumentDigest: "arg-digest",
            argumentByteCount: 10,
            argumentRedaction: "digestOnly",
            resultDigest: "res-digest",
            resultByteCount: 12,
            resultRedaction: "digestOnly",
            executionEnvironmentKind: "process",
            executionEnvironmentAdapterID: "default.process",
            executionIsolationLevel: "shared",
            source: "runtime.model.parity"
        )
        await manager.runtimeLifecyclePublicationService.publishRuntimeLifecycleWithFanout(payload)

        let topicCompleted = try #require((await recorder.runtimeLifecycleEvents()).last(where: {
            $0.name == .toolCallCompleted && $0.toolCallID == "tool-model-parity"
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
            $0.name == .toolCallCompleted && $0.toolCallID == "tool-model-parity"
        }
        let auditCompleted = try #require(matchingAudits.first)

        let trace = await manager.traceSnapshotForConversationAPI(conversationID: conversationID)
        let traceCompleted = try #require(trace.spans.last(where: {
            $0.name == RuntimeLifecycleEventName.toolCallCompleted.rawValue
                && $0.attributes?["toolCallID"] == "tool-model-parity"
        }))

        #expect(topicCompleted.toolCallID == auditCompleted.toolCallID)
        #expect(topicCompleted.toolCallID == traceCompleted.attributes?["toolCallID"])
        #expect(topicCompleted.toolName == auditCompleted.toolName)
        #expect(topicCompleted.toolName == traceCompleted.attributes?["toolName"])
        #expect(topicCompleted.argumentDigest == auditCompleted.argumentDigest)
        #expect(topicCompleted.argumentDigest == traceCompleted.attributes?["argumentDigest"])
        #expect(topicCompleted.executionEnvironmentKind == auditCompleted.executionEnvironmentKind)
        #expect(topicCompleted.executionEnvironmentKind == traceCompleted.attributes?["executionEnvironmentKind"])
    }

    @Test("startup-service conversation topic publisher reaches runtime lifecycle fanout")
    func startupServicePublisherReachesRuntimeLifecycle() async throws {
        let container = try RunLifecycleDurabilityTestSupport.makeContainer()
        let model = RunLifecycleDurabilityTestSupport.makeTestModel()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let recorder = RunDurabilityEventRecorder()
        await manager.conversationStartupService.setConversationTopicPublisher(recorder)
        try await manager.createConversation(with: model, userSystemPrompt: "startup-publisher")
        let conversationID = try #require(await manager.currentConversationID)
        let payload = RuntimeLifecycleEventPayload(
            name: .toolApprovalRequired,
            conversationID: conversationID,
            runID: UUID(),
            iteration: 1,
            toolName: "bash",
            toolCallID: "tool-approval-required",
            source: "test.startup-publisher"
        )
        await manager.runtimeLifecyclePublicationService.publishRuntimeLifecycleWithFanout(payload)

        let received = try #require((await recorder.runtimeLifecycleEvents()).last {
            $0.name == .toolApprovalRequired && $0.toolCallID == "tool-approval-required"
        })
        #expect(received.toolName == "bash")
    }
}
