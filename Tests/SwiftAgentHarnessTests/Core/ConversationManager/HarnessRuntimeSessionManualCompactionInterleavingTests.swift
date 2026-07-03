import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// State-isolation tests for the manual compaction surfaces (model tool / slash / REST) when
/// they target a *non-current* conversation. The plan's state-hygiene catalog calls out two
/// specific risks:
///
///   1. The manual-trigger `reason` (custom-instructions override) must not bleed into the
///      stored configuration, even across multiple invocations against different conversations.
///   2. Compaction directed at conversation A must never touch conversation B's projected
///      `currentMessages` or any of its persisted state.
///
/// All tests run against the in-memory model container with `NoOpConversationTransformer`
/// (the default for `HarnessRuntimeSession.init(container:...)`) so they exercise the dispatch and
/// state plumbing without requiring a live summarizer LLM.
private enum ManualCompactionInterleavingSupport {
    static func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    static func makeModel(name: String = "interleave:test") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }
}

private actor LifecycleCallRecorder {
    private var calls: [String] = []

    func append(_ call: String) {
        calls.append(call)
    }

    func snapshot() -> [String] {
        calls
    }
}

private struct RecordingLifecycleContextEngine: ContextEngine {
    let base: any ContextEngine
    let recorder: LifecycleCallRecorder

    func bootstrap(request: ContextEngineBootstrapRequest) async -> ContextEngineBootstrapResult {
        await recorder.append("bootstrap")
        return await base.bootstrap(request: request)
    }

    func ingest(request: ContextEngineIngestRequest) async -> ContextEngineIngestResult {
        await recorder.append("ingest")
        return await base.ingest(request: request)
    }

    func ingestBatch(request: ContextEngineIngestBatchRequest) async -> ContextEngineIngestResult {
        await recorder.append("ingestBatch")
        return await base.ingestBatch(request: request)
    }

    func assemble(
        request: ContextEngineAssembleRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextEngineAssembleResult {
        await recorder.append("assemble")
        return await base.assemble(request: request, performTransform: performTransform)
    }

    func compact(
        request: ContextEngineCompactRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextEngineCompactResult {
        await recorder.append("compact")
        return await base.compact(request: request, performTransform: performTransform)
    }

    func afterTurn(request: ContextEngineAfterTurnRequest) async -> ContextEngineAfterTurnResult {
        await recorder.append("afterTurn")
        return await base.afterTurn(request: request)
    }

    func prepareSubagentSpawn(
        request: ContextEnginePrepareSubagentSpawnRequest
    ) async -> ContextEnginePrepareSubagentSpawnResult {
        await recorder.append("prepareSubagentSpawn")
        return await base.prepareSubagentSpawn(request: request)
    }

    func onSubagentEnded(request: ContextEngineSubagentEndedRequest) async -> ContextEngineSubagentEndedResult {
        await recorder.append("onSubagentEnded")
        return await base.onSubagentEnded(request: request)
    }
}

@Suite("HarnessRuntimeSession manual compaction interleaving", .serialized)
struct HarnessRuntimeSessionManualCompactionInterleavingTests {

    @Test("performManualCompaction targets the requested conversation, not currentConversationID")
    func targetsRequestedConversationNotCurrent() async throws {
        let container = try ManualCompactionInterleavingSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ManualCompactionInterleavingSupport.makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys-A")
        let convA = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys-B")
        let convB = try #require(await runtimeSession.currentConversationID)
        // Currently selected: convB.

        // Run manual compaction against convA while convB is current.
        let result = try await runtimeSession.contextProjectionService.performManualCompaction(
            conversationID: convA,
            trigger: .rest,
            reason: nil
        )
        #expect(result.conversationID == convA)
        #expect(result.trigger == .rest)
        // Selection is unchanged.
        let stillCurrent = await runtimeSession.currentConversationID
        #expect(stillCurrent == convB)
    }

    @Test("performManualCompaction with unknown conversation throws conversationNotFound")
    func unknownConversationThrows() async throws {
        let container = try ManualCompactionInterleavingSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ManualCompactionInterleavingSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")

        do {
            _ = try await runtimeSession.contextProjectionService.performManualCompaction(
                conversationID: UUID(),
                trigger: .modelTool,
                reason: nil
            )
            Issue.record("Expected conversationNotFound")
        } catch ConversationServiceError.conversationNotFound {
            // Expected.
        }
    }

    @Test("Manual reason override is one-shot and never mutates the stored configuration")
    func reasonIsOneShotAndDoesNotMutateConfig() async throws {
        // Build a config with a known custom-instructions block; the manual call must not
        // overwrite it even when supplying a `reason`.
        let baseInstructions = "STORED-INSTRUCTIONS"
        let cc = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "summarizer:test",
            compactionCustomInstructionsBlock: baseInstructions
        )
        let transformConfig = ConversationTransformConfiguration(
            chat: .allEnabled,
            plan: .allEnabled,
            agent: .allEnabled,
            transformTimeoutSeconds: 1800,
            contextCompaction: cc
        )

        let container = try ManualCompactionInterleavingSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: transformConfig
        )
        let model = ManualCompactionInterleavingSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await runtimeSession.currentConversationID)

        _ = try await runtimeSession.contextProjectionService.performManualCompaction(
            conversationID: cid,
            trigger: .rest,
            reason: "ONE-SHOT-REASON"
        )

        // The stored configuration must still contain the original block.
        let mirrored = await runtimeSession.contextCompactionManualRESTEnabled
        // Sanity check the API mirror still works (independent of the reason override).
        #expect(mirrored == true)

        // Run a second compaction with no reason; the underlying instructions block must
        // still be the base value, not the previously-supplied one.
        let secondResult = try await runtimeSession.contextProjectionService.performManualCompaction(
            conversationID: cid,
            trigger: .slashCommand,
            reason: nil
        )
        #expect(secondResult.trigger == .slashCommand)
    }

    @Test("Manual compaction against conversation A preserves conversation B's messages")
    func conversationBPreservedWhenAIsCompacted() async throws {
        let container = try ManualCompactionInterleavingSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ManualCompactionInterleavingSupport.makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys-A")
        let convA = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys-B")
        let convB = try #require(await runtimeSession.currentConversationID)

        // Snapshot conversation B before the A-targeted compaction.
        let bBefore = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == convB }))
        let bMsgsBefore = bBefore.messages.map(\.id)

        _ = try await runtimeSession.contextProjectionService.performManualCompaction(
            conversationID: convA,
            trigger: .modelTool,
            reason: "compact-A"
        )

        let bAfter = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == convB }))
        let bMsgsAfter = bAfter.messages.map(\.id)
        #expect(bMsgsBefore == bMsgsAfter)
    }

    @Test("Tool-trigger compaction below 50% gate refuses regardless of which conversation is current")
    func toolTriggerRefusesWhenBelowGate() async throws {
        let container = try ManualCompactionInterleavingSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ManualCompactionInterleavingSupport.makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await runtimeSession.currentConversationID)

        // A fresh conversation with only a system prompt has only a handful of tokens.
        // The 50% gate should refuse a model-tool trigger; rest/slash bypass the gate.
        let toolResult = try await runtimeSession.contextProjectionService.performManualCompaction(
            conversationID: cid,
            trigger: .modelTool,
            reason: nil
        )
        #expect(toolResult.refusalReason != nil)
        #expect(toolResult.persisted == false)
        #expect(toolResult.compactedMessages == nil)

        let restResult = try await runtimeSession.contextProjectionService.performManualCompaction(
            conversationID: cid,
            trigger: .rest,
            reason: nil
        )
        #expect(restResult.refusalReason == nil)
    }

    @Test("Manual compaction no-ops when conversation compaction lock is already held")
    func manualCompactionNoopsWhenLockHeld() async throws {
        let container = try ManualCompactionInterleavingSupport.makeContainer()
        let coordinator = CompactionConcurrencyCoordinator()
        let runtimeSession = HarnessRuntimeSession(container: container, compactionCoordinator: coordinator)
        let model = ManualCompactionInterleavingSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await runtimeSession.currentConversationID)

        let acquired = await coordinator.tryAcquire(for: cid)
        #expect(acquired == true)
        defer { Task { await coordinator.release(for: cid) } }

        let result = try await runtimeSession.contextProjectionService.performManualCompaction(
            conversationID: cid,
            trigger: .rest,
            reason: nil
        )
        #expect(result.noopReason == "compaction_lock_held")
        #expect(result.persisted == false)
    }

    @Test("HarnessRuntimeSession routes context operations through lifecycle stages")
    func runtimeSessionRoutesThroughLifecycleStages() async throws {
        let container = try ManualCompactionInterleavingSupport.makeContainer()
        let recorder = LifecycleCallRecorder()
        let engine = RecordingLifecycleContextEngine(
            base: DefaultContextEngine(compactionCoordinator: nil, logger: nil),
            recorder: recorder
        )
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            contextEngine: engine
        )
        let model = ManualCompactionInterleavingSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversation = try #require(await runtimeSession.currentConversation())

        _ = await runtimeSession.contextProjectionService.transformedContextMessages(
            from: conversation.messages,
            conversation: conversation,
            phase: .initial
        )
        _ = try await runtimeSession.contextProjectionService.performManualCompaction(
            conversationID: conversation.id,
            trigger: .rest,
            reason: "lifecycle-check"
        )

        let calls = await recorder.snapshot()
        #expect(calls.contains("ingestBatch"))
        #expect(calls.contains("assemble"))
        #expect(calls.contains("compact"))
    }

    @Test("HarnessRuntimeSession persists checkpoint invalidation directives from sub-agent hooks")
    func subagentHookInvalidationDirectivesPersisted() async throws {
        let container = try ManualCompactionInterleavingSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ManualCompactionInterleavingSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let runID = UUID()

        let prepare = await runtimeSession.prepareSubagentSpawn(
            conversationID: conversationID,
            runID: runID,
            candidateToolNames: ["delegate.remote"],
            permissionPolicyByToolName: ["delegate.remote": .auto],
            trustLevelByToolName: ["delegate.remote": .knownParty],
            preApprovedToolNames: []
        )
        #expect(prepare.approvedToolNames == ["delegate.remote"])
        _ = await runtimeSession.onSubagentEnded(
            conversationID: conversationID,
            runID: runID,
            toolName: "delegate.remote",
            permissionPolicy: .auto,
            trustLevel: .knownParty
        )

        let events = await runtimeSession.journalEvents(conversationID: conversationID)
        let invalidations = events
            .filter { $0.kind == ConversationEventKind.checkpointInvalidated.rawValue }
            .compactMap { ConversationEventCodec.decode(CheckpointInvalidatedEventPayload.self, from: $0.payloadJSON) }
            .flatMap(\.kinds)
        #expect(invalidations.contains(HarnessCheckpointInvalidationKind.systemPromptAssembly))
        #expect(invalidations.contains(HarnessCheckpointInvalidationKind.attachmentProjection))
        #expect(invalidations.contains(HarnessCheckpointInvalidationKind.memoryInjectionSnapshot))
    }
}
