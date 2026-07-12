import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum StreamingTerminalStateTestSupport {
    static func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    static func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "stream-terminal:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func warmPool(
        _ manager: HarnessRuntimeSession,
        model: Model,
        conversationID: UUID
    ) async throws {
        let conversation = try #require(await manager.testing_modelConversation(conversationID: conversationID))
        await manager.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
    }
}

@Suite("HarnessRuntimeSession streaming terminal state", .serialized)
struct HarnessRuntimeSessionStreamingTerminalStateTests {
    private actor SnapshotCapture {
        private(set) var latest: ConversationOrchestrationState?
        private(set) var pushCount = 0

        func store(_ snapshot: ConversationOrchestrationState) {
            latest = snapshot
            pushCount += 1
        }
    }

    @Test("Terminal completion resets queued/started when conversation run id already nil")
    func terminalCompletionResetsQueuedStartedWithNilConversationRunID() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        try await StreamingTerminalStateTestSupport.warmPool(manager, model: model, conversationID: conversationID)
        let runID = UUID()

        await manager.testing_setActiveStreamingRun(conversationID: conversationID, runID: runID)
        defer { Task { await manager.testing_setActiveStreamingRun(conversationID: nil, runID: nil) } }

        // Reproduce drift: phases still queued/started while conversation.currentRunID has already been cleared.
        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: nil
        )

        let before = await manager.snapshotOrchestrationState(for: conversationID)
        let beforeSnapshot = try #require(before)
        #expect(beforeSnapshot.agenticPhase == .started)
        #expect(beforeSnapshot.llmRequestPhase == .queued)

        await manager.markStreamingGenerationCompleteIfCurrent(
            token: 0,
            terminalStatus: .completed,
            terminalReason: nil,
            markerKind: nil,
            conversationID: conversationID,
            runID: runID
        )

        let conversationInfo = try #require(await manager.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(conversationInfo.state == .idle)
        #expect(conversationInfo.agenticPhase == .idle)

        let after = await manager.snapshotOrchestrationState(for: conversationID)
        let afterSnapshot = try #require(after)
        #expect(afterSnapshot.agenticPhase == .idle)
        #expect(afterSnapshot.llmRequestPhase == .idle)
        #expect(afterSnapshot.currentRunID == nil)
    }

    @Test("Topic orchestration refresh forces idle snapshot when no active streaming run")
    func topicRefreshForcesTerminalIdleWhenNoActiveRun() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let staleRunID = UUID()
        let capture = SnapshotCapture()
        // Reproduce stale persisted runtime flags with no active runtime run.
        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: staleRunID
        )
        await manager.testing_setActiveStreamingRun(conversationID: nil, runID: nil)
        await manager.agentRuntimeSessionService.setOrchestrationStateTopicRefreshHandler { _, snapshot in
            await capture.store(snapshot)
        }

        await manager.emitOrchestrationStateFromLiveSources()

        let emitted = try #require(await capture.latest)
        #expect(emitted.agenticPhase == .idle)
        #expect(emitted.llmRequestPhase == .idle)
        #expect(emitted.currentRunID == nil)
        await manager.agentRuntimeSessionService.clearOrchestrationStateTopicRefreshHandler()
    }

    @Test("Terminal completion clears active run even when generation token mismatches")
    func terminalCompletionClearsActiveRunOnGenerationMismatch() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()
        let capture = SnapshotCapture()
        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: runID
        )
        await manager.testing_setActiveStreamingRun(conversationID: conversationID, runID: runID)

        // Simulate a stale completion callback whose token no longer matches the latest sequence.
        await manager.markStreamingGenerationCompleteIfCurrent(
            token: 999,
            terminalStatus: .completed,
            terminalReason: nil,
            markerKind: nil,
            conversationID: conversationID,
            runID: runID
        )

        // Re-introduce stale persisted flags; if active run cleanup failed, snapshot emission
        // will continue to publish queued/started instead of a forced terminal idle snapshot.
        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: runID
        )
        await manager.agentRuntimeSessionService.setOrchestrationStateTopicRefreshHandler { _, snapshot in
            await capture.store(snapshot)
        }

        await manager.emitOrchestrationStateFromLiveSources()

        let emitted = try #require(await capture.latest)
        #expect(emitted.agenticPhase == .idle)
        #expect(emitted.llmRequestPhase == .idle)
        #expect(emitted.currentRunID == nil)
        await manager.agentRuntimeSessionService.clearOrchestrationStateTopicRefreshHandler()
    }

    @Test("Message append path preserves latest runtime idle state")
    func messageAppendPathPreservesLatestRuntimeIdleState() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let staleRunID = UUID()

        // Build a stale snapshot representing a pre-terminal append worker.
        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: staleRunID
        )
        var staleSnapshot = try #require(await manager.testing_modelConversation(conversationID: conversationID))

        // Runtime has already transitioned to idle by the time append writes back.
        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .idle,
            agenticPhase: .idle,
            llmRequestPhase: nil,
            currentRunID: nil
        )

        staleSnapshot.state = .generating
        staleSnapshot.agenticPhase = .started
        staleSnapshot.llmRequestPhase = .queued
        staleSnapshot.currentRunID = staleRunID
        let merged = await manager.testing_mergeRuntimeState(
            conversationID: conversationID,
            snapshot: staleSnapshot
        )

        #expect(merged.state == .idle)
        #expect(merged.agenticPhase == .idle)
        #expect(merged.llmRequestPhase == nil)
        #expect(merged.currentRunID == nil)
    }

    @Test("Terminal completion preserves existing transcript rows")
    func terminalCompletionPreservesExistingTranscriptRows() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()

        await manager.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .assistant, content: "before-terminal"),
        ])
        let before = try #require(await manager.testing_modelConversation(conversationID: conversationID))
        #expect(before.messages.contains(where: { $0.role == .assistant && $0.content == "before-terminal" }))

        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: runID
        )
        await manager.testing_setActiveStreamingRun(conversationID: conversationID, runID: runID)
        defer { Task { await manager.testing_setActiveStreamingRun(conversationID: nil, runID: nil) } }

        await manager.markStreamingGenerationCompleteIfCurrent(
            token: 0,
            terminalStatus: .completed,
            terminalReason: nil,
            markerKind: nil,
            conversationID: conversationID,
            runID: runID
        )

        let after = try #require(await manager.testing_modelConversation(conversationID: conversationID))
        #expect(after.messages.contains(where: { $0.role == .assistant && $0.content == "before-terminal" }))
        #expect(after.messages.count == before.messages.count)
    }

    @Test("Duplicate idle orchestration emissions coalesce topic refresh")
    func duplicateIdleOrchestrationEmissionsCoalesceTopicRefresh() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let capture = SnapshotCapture()
        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .idle,
            agenticPhase: .idle,
            llmRequestPhase: .idle,
            currentRunID: nil
        )
        await manager.testing_setActiveStreamingRun(conversationID: nil, runID: nil)
        await manager.agentRuntimeSessionService.setOrchestrationStateTopicRefreshHandler { _, snapshot in
            await capture.store(snapshot)
        }

        await manager.emitOrchestrationStateFromLiveSources(preferredConversationID: conversationID)
        await manager.emitOrchestrationStateFromLiveSources(preferredConversationID: conversationID)

        #expect(await capture.pushCount == 1)
        await manager.agentRuntimeSessionService.clearOrchestrationStateTopicRefreshHandler()
    }

    @Test("Orchestration emission forwards topic refresh even when stream continuation is active")
    func orchestrationEmissionForwardsTopicRefreshWhileContinuationActive() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let capture = SnapshotCapture()
        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: UUID()
        )
        await manager.testing_setActiveStreamingRun(conversationID: conversationID, runID: UUID())
        await manager.testing_installTurnStateContinuation()
        await manager.agentRuntimeSessionService.setOrchestrationStateTopicRefreshHandler { _, snapshot in
            await capture.store(snapshot)
        }

        await manager.emitOrchestrationStateFromLiveSources(preferredConversationID: conversationID)

        let emitted = await capture.latest
        #expect(emitted != nil)

        await manager.agentRuntimeSessionService.clearOrchestrationStateTopicRefreshHandler()
        await manager.testing_clearTurnStateContinuation()
    }

    @Test("Orchestration topic refresh receives emitted conversation id")
    func orchestrationTopicRefreshReceivesEmittedConversationID() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        actor RefreshCapture {
            private(set) var conversationID: UUID?
            func store(cid: UUID, _: ConversationOrchestrationState) {
                conversationID = cid
            }
        }
        let capture = RefreshCapture()
        await manager.agentRuntimeSessionService.setOrchestrationStateTopicRefreshHandler { cid, snapshot in
            await capture.store(cid: cid, snapshot)
        }

        await manager.emitOrchestrationStateFromLiveSources(preferredConversationID: conversationID)

        #expect(await capture.conversationID == conversationID)
        await manager.agentRuntimeSessionService.clearOrchestrationStateTopicRefreshHandler()
    }

    @Test("Snapshot forces streaming phases even without bound orchestrator")
    func snapshotForcesStreamingPhasesWithoutBoundOrchestrator() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()

        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: runID
        )
        try await StreamingTerminalStateTestSupport.warmPool(manager, model: model, conversationID: conversationID)
        await manager.testing_setActiveStreamingRun(conversationID: conversationID, runID: runID)
        await manager.testing_setContentStreamingActive(true)
        defer {
            Task {
                await manager.testing_setContentStreamingActive(false)
                await manager.testing_setActiveStreamingRun(conversationID: nil, runID: nil)
            }
        }

        let snapshot = try #require(await manager.snapshotOrchestrationState(for: conversationID))
        #expect(snapshot.llmRequestPhase == .streaming)
        #expect(snapshot.llmRuntimePhase == .generatingResponding)
        #expect(snapshot.agenticPhase == .started)

        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .idle,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: runID
        )
        await manager.testing_setContentStreamingActive(false)
        await manager.testing_setActiveStreamingRun(conversationID: nil, runID: nil)

        let terminalSnapshot = try #require(await manager.snapshotOrchestrationState(for: conversationID))
        #expect(terminalSnapshot.llmRequestPhase == .idle)
        #expect(terminalSnapshot.llmRuntimePhase == .idleReady)
        #expect(terminalSnapshot.agenticPhase == .idle)
        #expect(terminalSnapshot.currentRunID == nil)
    }

    @Test("Snapshot treats stale active run as terminal when no generation task is running")
    func snapshotTreatsStaleActiveRunAsTerminalWithoutGenerationTask() async throws {
        let container = try StreamingTerminalStateTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = StreamingTerminalStateTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()

        await manager.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: runID
        )
        await manager.testing_setContentStreamingActive(false)
        await manager.testing_setActiveStreamingRun(conversationID: conversationID, runID: runID)
        await manager.testing_setGenerationTaskActive(false)

        let snapshot = try #require(await manager.snapshotOrchestrationState(for: conversationID))
        #expect(snapshot.llmRequestPhase == .idle)
        #expect(snapshot.llmRuntimePhase == .idleReady)
        #expect(snapshot.agenticPhase == .idle)
        #expect(snapshot.currentRunID == nil)
    }

    @Test("Orchestrator message routing falls back to active streaming conversation in API sessions")
    func orchestratorMessageRoutingFallsBackToActiveStreamingConversationInAPISession() async throws {
        let namespace = UUID()
        try await APISessionContext.$connectionNamespace.withValue(namespace) {
            let container = try StreamingTerminalStateTestSupport.makeContainer()
            let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
            let model = StreamingTerminalStateTestSupport.makeModel()
            try await manager.createConversation(with: model, userSystemPrompt: "sys")

            let conversationID = try #require(await manager.listConversationInfo().first?.id)
            #expect(await manager.currentConversationID == nil)

            try await StreamingTerminalStateTestSupport.warmPool(manager, model: model, conversationID: conversationID)
            let runID = UUID()
            await manager.testing_setActiveStreamingRun(conversationID: conversationID, runID: runID)
            defer { Task { await manager.testing_setActiveStreamingRun(conversationID: nil, runID: nil) } }

            let assistant = Message(id: UUID(), role: .assistant, content: "streamed reply")
            await manager.testing_applyOrchestratorMessages([assistant])

            let updated = try #require(await manager.testing_modelConversation(conversationID: conversationID))
            #expect(updated.messages.contains(where: { $0.id == assistant.id }))
        }
    }
}
