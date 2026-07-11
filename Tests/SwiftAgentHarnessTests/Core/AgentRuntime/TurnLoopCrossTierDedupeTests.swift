import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop cross-tier memory dedupe")
struct TurnLoopCrossTierDedupeTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "turn-loop-dedupe",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("blocking recall receives projected tier2 selection keys from context port")
    func blockingRecallReceivesProjectedKeys() async throws {
        let model = makeModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "find notes", timestamp: Date())],
            turns: [],
            interactionMode: .chat
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let projectedKeys: Set<String> = ["topic-a.md", "user/prefs.md"]
        let exclusionCapture = ExclusionKeysCapture()
        let basePorts = TurnLoopTestPorts.make(state: state)
        let contextPort = SessionRuntimeContextPort(
            bootstrapFn: { _, _ in },
            assembleFn: { _, _, _, _, _ in await state.snapshot().messages },
            projectedMemorySelectionKeysFn: { _ in projectedKeys },
            afterTurnFn: { _, _, _ in }
        )
        let memoryPort = SessionRuntimeMemoryPort(
            recallFn: { _, _, _, _, excluded in
                await exclusionCapture.record(excluded)
                return ActiveMemoryRecallOutcome(
                    note: nil,
                    diagnostics: ActiveMemoryTurnDiagnostics(
                        status: .none,
                        elapsedMs: 0,
                        queryMode: .recent,
                        summaryChars: 0,
                        note: nil,
                        skipReason: nil
                    )
                )
            },
            prefetchFn: { _, _, _, _ in }
        )
        let modelPort = SessionRuntimeModelPort(
            ensureBoundFn: { conv, _ in conv.model.id },
            streamLLM: { _, _, _, _, _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
                    continuation.finish()
                }
            }
        )
        let ports = AgentLoopPorts(
            model: modelPort,
            context: contextPort,
            tools: basePorts.tools,
            conversation: basePorts.conversation,
            memory: memoryPort,
            agentHarness: basePorts.agentHarness,
            contextCompaction: basePorts.contextCompaction,
            modeRegistry: basePorts.modeRegistry,
            logger: basePorts.logger
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let captured = await exclusionCapture.keys()
        #expect(captured == projectedKeys)
    }

    @Test("recallOutcomeIfEnabled invalidates situational cache when exclusions are non-empty")
    func exclusionsInvalidateSituationalCache() async {
        let tracker = CrossTierRecallCallTracker()
        let runner = CrossTierSpyRunner(tracker: tracker, returnValue: "cached situational")
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(runner)
        let session = MemorySessionContext(
            conversationID: UUID(),
            cwd: "/tmp",
            canonicalGitRoot: nil,
            memoryDirectory: URL(fileURLWithPath: "/tmp/memory")
        )
        let first = await service.situationalSummary(session: session, userQuery: "query-a")
        #expect(first == "cached situational")
        #expect(await tracker.callCount() == 1)

        _ = await service.recallOutcomeIfEnabled(
            session: session,
            userQuery: "query-a",
            sessionEnabled: true,
            excludedSelectionKeys: ["topic-a.md"]
        )
        #expect(await tracker.callCount() >= 2)
    }
}

private actor CrossTierRecallCallTracker {
    private(set) var count = 0

    func record() {
        count += 1
    }

    func callCount() -> Int { count }
}

private struct CrossTierSpyRunner: ActiveMemoryPreReplyRunning {
    let tracker: CrossTierRecallCallTracker
    let returnValue: String?

    func blockingRecallSummary(
        session: MemorySessionContext,
        userQuery: String?,
        lane: RecallLane,
        timeoutMs: Int,
        maxSummaryChars: Int,
        excludedSelectionKeys: Set<String>
    ) async -> String? {
        let _ = (session, userQuery, lane, timeoutMs, maxSummaryChars, excludedSelectionKeys)
        await tracker.record()
        return returnValue
    }
}

private actor ExclusionKeysCapture {
    private(set) var captured: Set<String> = []

    func record(_ keys: Set<String>) {
        captured = keys
    }

    func keys() -> Set<String> { captured }
}
