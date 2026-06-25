import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor StubReplayTransformer: ConversationTransforming {
    private(set) var contextCalls: Int = 0
    private(set) var turnCalls: Int = 0

    func transformContext(_ input: ContextTransformInput) async throws -> ContextTransformOutput {
        contextCalls += 1
        return ContextTransformOutput(messages: input.messages, diagnostics: "stub_context", messageProvenance: nil)
    }

    func transformTurnSummary(_ input: TurnSummaryTransformInput) async throws -> TurnSummaryTransformOutput {
        turnCalls += 1
        return TurnSummaryTransformOutput(replacementTurnMessages: input.turnMessages, diagnostics: "stub_turn")
    }

    func counts() async -> (Int, Int) {
        (contextCalls, turnCalls)
    }
}

private actor ReplayToolMiddlewareProbe {
    private(set) var calls: Int = 0
    func record() { calls += 1 }
    func count() -> Int { calls }
}

private actor StreamCountCollector {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }
}

@Suite("HarnessRuntimeSession replay processing", .serialized)
struct HarnessRuntimeSessionReplayProcessingTests {
    /// Compaction disabled so token-based gating does not skip `transformContext` on short replay transcripts.
    private func replayTransformConfig() -> ConversationTransformConfiguration {
        let d = ConversationTransformConfiguration.default
        var cc = d.contextCompaction
        cc.enabled = false
        return ConversationTransformConfiguration(
            chat: d.chat,
            plan: d.plan,
            agent: d.agent,
            transformTimeoutSeconds: d.transformTimeoutSeconds,
            contextCompaction: cc
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "replay-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func seedReplayConversation(host: HarnessRuntimeSession, model: Model) async throws -> UUID {
        let base = Date()
        let user = Message(id: UUID(), role: .user, content: "Find release notes", timestamp: base)
        let assistantToolCall = Message(
            id: UUID(),
            role: .assistant,
            content: "Calling tool",
            timestamp: base.addingTimeInterval(1),
            toolCalls: [
                ToolCall(
                    name: "web_fetch",
                    arguments: .object(["url": .string("https://example.com")]),
                    instructions: "",
                    id: "tc-1"
                ),
            ]
        )
        let toolResult = Message(
            id: UUID(),
            role: .tool,
            content: "raw tool output",
            timestamp: base.addingTimeInterval(2),
            toolCalls: [],
            toolCallId: "tc-1"
        )
        let assistantFinal = Message(
            id: UUID(),
            role: .assistant,
            content: "Done.",
            timestamp: base.addingTimeInterval(3),
            toolCalls: []
        )
        return try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: host,
            model: model,
            systemPrompt: "sys",
            extraMessages: [user, assistantToolCall, toolResult, assistantFinal]
        )
    }

    private func seedBulkReplayConversation(
        host: HarnessRuntimeSession,
        model: Model,
        pairCount: Int,
        emptyAssistantOnEvenIndex: Bool
    ) async throws -> UUID {
        let base = Date()
        var extra: [Message] = []
        for index in 0 ..< pairCount {
            extra.append(Message(
                id: UUID(),
                role: .user,
                content: "u\(index)",
                timestamp: base.addingTimeInterval(Double(index * 2)),
                toolCalls: []
            ))
            let assistantContent = emptyAssistantOnEvenIndex && index % 2 == 0 ? "" : "a\(index)"
            extra.append(Message(
                id: UUID(),
                role: .assistant,
                content: assistantContent,
                timestamp: base.addingTimeInterval(Double(index * 2 + 1)),
                toolCalls: []
            ))
        }
        return try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: host,
            model: model,
            systemPrompt: "sys",
            extraMessages: extra
        )
    }

    private func makeReplayHost(
        fixture: InMemoryHarnessRuntimeHostFixture,
        transformer: StubReplayTransformer
    ) -> HarnessRuntimeSession {
        return HarnessRuntimeSession(
            persistenceDomain: fixture.domain,
            logger: nil,
            toolPolicy: .unrestricted,
            agentHarness: .default,
            conversationTransformConfiguration: replayTransformConfig(),
            conversationTransformer: transformer,
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            compactionCoordinator: CompactionConcurrencyCoordinator(),
            contextEngine: nil
        )
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool,
        timeoutMS: Int = 3000
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        while Date() < deadline {
            if await predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func teardownReplayFixture(_ fixture: InMemoryHarnessRuntimeHostFixture, runtimeSession: HarnessRuntimeSession) async {
        await runtimeSession.agentRuntimeSessionService.cancelMessageStreamForAPI()
        await runtimeSession.shutdownOrchestratorAndToolRuntimes()
    }

    @Test("startConversationReplay replays messages and invokes transform hooks")
    func replayInvokesTransformHooks() async throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let model = makeModel()
        let conversationID = try await seedReplayConversation(host: fixture.host, model: model)

        let transformer = StubReplayTransformer()
        let runtimeSession = makeReplayHost(fixture: fixture, transformer: transformer)
        let toolProbe = ReplayToolMiddlewareProbe()
        await runtimeSession.orchestratorRuntimeService.registerAgentToolResultMiddleware(
            AgentToolResultMiddleware(id: "replay-tool-probe") { _, result in
                await toolProbe.record()
                return ToolResult(
                    success: result.success,
                    content: "[tool-transformed] \(result.content)",
                    metadata: result.metadata,
                    toolCallId: result.toolCallId
                )
            }
        )
        try await runtimeSession.resetConversationsFromCatalog(availableModels: [model])
        try await runtimeSession.selectConversation(conversationID: conversationID)
        try await runtimeSession.conversationReplayService.startConversationReplay(sourceConversationID: conversationID)

        guard await waitUntil(
            { await runtimeSession.conversationReplayService.isConversationReplayActive(conversationID: conversationID) == false },
            timeoutMS: 15_000
        ) else {
            Issue.record("timed out waiting for conversation replay to finish")
            await teardownReplayFixture(fixture, runtimeSession: runtimeSession)
            return
        }
        let replayed = try await runtimeSession.listCurrentMessages()
        #expect(replayed.count == 5)
        // Sandbox replay does not mutate the source transcript; tool text stays as persisted.
        #expect(replayed.contains(where: { $0.role == .tool && $0.content == "raw tool output" }))
        let counts = await transformer.counts()
        #expect(counts.0 > 0) // context
        #expect(counts.1 > 0) // turn
        #expect(await toolProbe.count() > 0) // host tool-result middleware applied during replay
        await teardownReplayFixture(fixture, runtimeSession: runtimeSession)
    }

    @Test("stopConversationReplay cancels an active replay task")
    func stopReplayCancels() async throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let model = makeModel()
        let conversationID = try await seedBulkReplayConversation(host: fixture.host, model: model, pairCount: 25, emptyAssistantOnEvenIndex: false)
        let expectedMessageCount = 1 + 25 * 2
        let transformer = StubReplayTransformer()
        let runtimeSession = makeReplayHost(fixture: fixture, transformer: transformer)
        try await runtimeSession.resetConversationsFromCatalog(availableModels: [model])
        try await runtimeSession.selectConversation(conversationID: conversationID)
        try await runtimeSession.conversationReplayService.startConversationReplay(sourceConversationID: conversationID)
        try await Task.sleep(nanoseconds: 120_000_000)
        await runtimeSession.conversationReplayService.stopConversationReplay(conversationID: conversationID)
        guard await waitUntil(
            { await runtimeSession.conversationReplayService.isConversationReplayActive(conversationID: conversationID) == false },
            timeoutMS: 15_000
        ) else {
            Issue.record("timed out waiting for conversation replay stop")
            await teardownReplayFixture(fixture, runtimeSession: runtimeSession)
            return
        }

        let replayed = try await runtimeSession.listCurrentMessages()
        // Non-destructive replay: source conversation row count is unchanged (replay runs in a sandbox).
        #expect(replayed.count == expectedMessageCount)
        await teardownReplayFixture(fixture, runtimeSession: runtimeSession)
    }

    @Test("replay stream drives projection without stale drops under churn")
    func replayStreamProjectionStableUnderChurn() async throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let model = makeModel()
        let conversationID = try await seedBulkReplayConversation(
            host: fixture.host,
            model: model,
            pairCount: 80,
            emptyAssistantOnEvenIndex: true
        )
        let transformer = StubReplayTransformer()
        let runtimeSession = makeReplayHost(fixture: fixture, transformer: transformer)
        try await runtimeSession.resetConversationsFromCatalog(availableModels: [model])
        try await runtimeSession.selectConversation(conversationID: conversationID)
        let stream = try await runtimeSession.agentRuntimeSessionService.messageStream(for: conversationID)
        let collectorState = StreamCountCollector()
        let collector = Task {
            for await messages in stream {
                await collectorState.append(messages.count)
                let snapshot = await collectorState.snapshot()
                if snapshot.count > 600 {
                    break
                }
            }
        }

        try await runtimeSession.conversationReplayService.startConversationReplay(sourceConversationID: conversationID)
        guard await waitUntil(
            { await runtimeSession.conversationReplayService.isConversationReplayActive(conversationID: conversationID) == false },
            timeoutMS: 30_000
        ) else {
            Issue.record("timed out waiting for bulk conversation replay to finish")
            collector.cancel()
            _ = await collector.result
            await teardownReplayFixture(fixture, runtimeSession: runtimeSession)
            return
        }
        collector.cancel()
        _ = await collector.result
        await teardownReplayFixture(fixture, runtimeSession: runtimeSession)
        let observedCounts = await collectorState.snapshot()

        let startIndex = observedCounts.firstIndex(of: 1) ?? 0
        let replaySequence = Array(observedCounts.dropFirst(startIndex))
        #expect(!replaySequence.isEmpty)
        // Counts can move up and down while replay rebuilds and projection catches up; the
        // regression we care about here is stale projection drops (see HarnessRuntimeSession projection tests).
        let peak = replaySequence.max() ?? 0
        #expect(peak >= 30)
        let metrics = await runtimeSession.contextProjectionService.projectionHardeningMetrics()
        #expect(metrics.staleProjectionDropCount == 0)
    }

    @Test("Replay active/stop follow ConversationSelectionLedger when connection namespaces differ")
    func replayLifecycleUsesSessionScopedSelectionWithDistinctNamespaces() async throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let model = makeModel()
        let conversationID = try await seedReplayConversation(host: fixture.host, model: model)

        let transformer = StubReplayTransformer()
        let runtimeSession = makeReplayHost(fixture: fixture, transformer: transformer)
        try await runtimeSession.resetConversationsFromCatalog(availableModels: [model])

        let nsA = UUID()
        let nsB = UUID()

        try await APISessionContext.$connectionNamespace.withValue(nsA) {
            try await runtimeSession.selectConversation(conversationID: conversationID)
            try await runtimeSession.conversationReplayService.startConversationReplay(sourceConversationID: conversationID)
        }

        let otherID = try await APISessionContext.$connectionNamespace.withValue(nsB) {
            try await runtimeSession.createConversation(with: model, userSystemPrompt: "other-session-marker")
        }

        let activeOnB = await APISessionContext.$connectionNamespace.withValue(nsB) {
            await runtimeSession.conversationReplayService.isConversationReplayActive(conversationID: otherID)
        }
        #expect(activeOnB == false)

        let activeOnA = await APISessionContext.$connectionNamespace.withValue(nsA) {
            await runtimeSession.conversationReplayService.isConversationReplayActive(conversationID: conversationID)
        }
        #expect(activeOnA == true)

        await APISessionContext.$connectionNamespace.withValue(nsA) {
            await runtimeSession.conversationReplayService.stopConversationReplay(conversationID: conversationID)
        }
        guard await waitUntil({
            await APISessionContext.$connectionNamespace.withValue(nsA) {
                await runtimeSession.conversationReplayService.isConversationReplayActive(conversationID: conversationID)
            } == false
        }, timeoutMS: 15_000) else {
            Issue.record("timed out waiting for namespaced conversation replay stop")
            await teardownReplayFixture(fixture, runtimeSession: runtimeSession)
            return
        }
        await teardownReplayFixture(fixture, runtimeSession: runtimeSession)
    }
}
