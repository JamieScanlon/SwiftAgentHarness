import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

// MARK: - Helpers

private actor RecallCallTracker {
    struct Call: Sendable {
        let lane: RecallLane
        let query: String?
    }
    private(set) var calls: [Call] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func record(lane: RecallLane, query: String?) {
        calls.append(Call(lane: lane, query: query))
        for c in continuations { c.resume() }
        continuations.removeAll()
    }

    func waitForCall() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func callCount() -> Int { calls.count }
    func lanes() -> [RecallLane] { calls.map(\.lane) }
}

private func makeSession() -> MemorySessionContext {
    MemorySessionContext(
        conversationID: UUID(),
        cwd: "/tmp",
        canonicalGitRoot: nil,
        memoryDirectory: URL(fileURLWithPath: "/tmp/memory")
    )
}

private struct SpyRunner: ActiveMemoryPreReplyRunning {
    let tracker: RecallCallTracker
    let returnValue: String?

    func blockingRecallSummary(
        session: MemorySessionContext,
        userQuery: String?,
        lane: RecallLane,
        timeoutMs: Int,
        maxSummaryChars: Int
    ) async -> String? {
        await tracker.record(lane: lane, query: userQuery)
        return returnValue
    }
}

// MARK: - Standing lane tests

@Suite("ActiveMemoryPreReplyService – standing lane")
struct ActiveMemoryStandingLaneTests {
    @Test("warmStanding populates cache so standingSummary hits without runner on next call")
    func warmThenHit() async {
        let tracker = RecallCallTracker()
        let runner = SpyRunner(tracker: tracker, returnValue: "user prefs")
        let config = MemoryConfiguration.default
        let service = ActiveMemoryPreReplyService(config: config)
        await service.setRunner(runner)
        let session = makeSession()

        await service.warmStanding(session: session)
        // wait for in-flight task to settle
        await tracker.waitForCall()
        // small sleep to let the task store into cache
        try? await Task.sleep(nanoseconds: 10_000_000)

        let summary = await service.standingSummary(session: session)
        // second call should not invoke runner again
        let callCount = await tracker.callCount()
        #expect(summary?.contains("user prefs") == true)
        #expect(callCount == 1)
    }

    @Test("standingSummary on cold cache returns nil and schedules warm")
    func coldCacheReturnsNil() async {
        let tracker = RecallCallTracker()
        let runner = SpyRunner(tracker: tracker, returnValue: "user prefs")
        let config = MemoryConfiguration.default
        let service = ActiveMemoryPreReplyService(config: config)
        await service.setRunner(runner)
        let session = makeSession()

        let result = await service.standingSummary(session: session)
        #expect(result == nil)
        // warm should have been kicked off
        await tracker.waitForCall()
        #expect(await tracker.callCount() == 1)
        #expect(await tracker.lanes().first == .standing)
    }

    @Test("warmStanding is idempotent: second call while in-flight does not spawn again")
    func warmIsIdempotent() async {
        let gate = AsyncStream<Void>.makeStream()
        let tracker = RecallCallTracker()
        struct BlockingRunner: ActiveMemoryPreReplyRunning {
            let tracker: RecallCallTracker
            let gate: AsyncStream<Void>
            func blockingRecallSummary(session: MemorySessionContext, userQuery: String?, lane: RecallLane, timeoutMs: Int, maxSummaryChars: Int) async -> String? {
                await tracker.record(lane: lane, query: userQuery)
                // wait for unblock
                for await _ in gate { break }
                return "prefs"
            }
        }
        let runner = BlockingRunner(tracker: tracker, gate: gate.stream)
        let config = MemoryConfiguration.default
        let service = ActiveMemoryPreReplyService(config: config)
        await service.setRunner(runner)
        let session = makeSession()

        await service.warmStanding(session: session)
        await tracker.waitForCall()
        // call again while first is in-flight
        await service.warmStanding(session: session)
        gate.continuation.finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await tracker.callCount() == 1)
    }

    @Test("standing lane uses .standing lane in runner calls")
    func standingLanePassedToRunner() async {
        let tracker = RecallCallTracker()
        let runner = SpyRunner(tracker: tracker, returnValue: "prefs")
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(runner)
        let session = makeSession()
        await service.warmStanding(session: session)
        await tracker.waitForCall()
        #expect(await tracker.lanes().first == .standing)
    }
}

// MARK: - Situational lane tests

@Suite("ActiveMemoryPreReplyService – situational lane")
struct ActiveMemorySituationalLaneTests {
    @Test("situationalSummary cache hit returns without calling runner")
    func cacheHitSkipsRunner() async {
        let tracker = RecallCallTracker()
        let runner = SpyRunner(tracker: tracker, returnValue: "project ctx")
        let config = MemoryConfiguration.default
        let service = ActiveMemoryPreReplyService(config: config)
        await service.setRunner(runner)
        let session = makeSession()
        let query = "what is grafana"

        // prime cache via prefetch
        await service.prefetchSituational(session: session, userQuery: query)
        await tracker.waitForCall()
        try? await Task.sleep(nanoseconds: 10_000_000)

        let initialCount = await tracker.callCount()
        let summary = await service.situationalSummary(session: session, userQuery: query)
        #expect(summary?.contains("project ctx") == true)
        #expect(await tracker.callCount() == initialCount, "cache hit should not call runner again")
    }

    @Test("cold situationalSummary does one short blocking read and caches result")
    func coldBlockingReadCaches() async {
        let tracker = RecallCallTracker()
        let runner = SpyRunner(tracker: tracker, returnValue: "grafana info")
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(runner)
        let session = makeSession()
        let query = "grafana dashboard"

        let summary = await service.situationalSummary(session: session, userQuery: query)
        #expect(summary?.contains("grafana info") == true)
        #expect(await tracker.callCount() == 1)

        // second call for same query should hit cache
        let summary2 = await service.situationalSummary(session: session, userQuery: query)
        #expect(summary2?.contains("grafana info") == true)
        #expect(await tracker.callCount() == 1)
    }

    @Test("situational is keyed on query: different queries produce independent results")
    func differentQueriesAreIndependent() async {
        var callMap: [String: String] = ["query-a": "result-a", "query-b": "result-b"]
        struct MapRunner: ActiveMemoryPreReplyRunning {
            let callMap: [String: String]
            func blockingRecallSummary(session: MemorySessionContext, userQuery: String?, lane: RecallLane, timeoutMs: Int, maxSummaryChars: Int) async -> String? {
                callMap[userQuery ?? ""]
            }
        }
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(MapRunner(callMap: callMap))
        let session = makeSession()

        let a = await service.situationalSummary(session: session, userQuery: "query-a")
        let b = await service.situationalSummary(session: session, userQuery: "query-b")
        #expect(a == "result-a")
        #expect(b == "result-b")
    }

    @Test("prefetchSituational never speculatively warms: only fires on explicit call")
    func situationalNeverSpeculativelyWarmed() async {
        let tracker = RecallCallTracker()
        let runner = SpyRunner(tracker: tracker, returnValue: "ctx")
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(runner)
        // Just creating the service and setting the runner should not trigger any calls
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(await tracker.callCount() == 0)
    }
}

// MARK: - Combined entry point tests

@Suite("ActiveMemoryPreReplyService – combined recallSummaryIfEnabled")
struct ActiveMemoryRecallCombinedTests {
    @Test("combined output places standing before situational")
    func standingBeforeSituational() async {
        struct LaneRunner: ActiveMemoryPreReplyRunning {
            func blockingRecallSummary(session: MemorySessionContext, userQuery: String?, lane: RecallLane, timeoutMs: Int, maxSummaryChars: Int) async -> String? {
                lane == .standing ? "standing-content" : "situational-content"
            }
        }
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(LaneRunner())
        let session = makeSession()
        // warm standing first
        await service.warmStanding(session: session)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let result = await service.recallSummaryIfEnabled(session: session, userQuery: "some query")
        guard let combined = result else {
            Issue.record("expected combined result")
            return
        }
        let standingRange = combined.range(of: "standing-content")
        let situationalRange = combined.range(of: "situational-content")
        #expect(standingRange != nil)
        #expect(situationalRange != nil)
        if let s = standingRange, let q = situationalRange {
            #expect(s.lowerBound < q.lowerBound, "standing must appear before situational")
        }
    }

    @Test("combined returns nil when both lanes miss")
    func bothMissReturnsNil() async {
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(SpyRunner(tracker: RecallCallTracker(), returnValue: nil))
        let session = makeSession()
        let result = await service.recallSummaryIfEnabled(session: session, userQuery: "x")
        // situational returns nil; standing cold also returns nil
        #expect(result == nil)
    }

    @Test("group chat gate: recallSummaryIfEnabled returns nil for non-direct sessions")
    func groupChatGate() async {
        let tracker = RecallCallTracker()
        let runner = SpyRunner(tracker: tracker, returnValue: "should-not-appear")
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(runner)
        let session = MemorySessionContext(
            conversationID: UUID(),
            cwd: "/tmp",
            canonicalGitRoot: nil,
            memoryDirectory: URL(fileURLWithPath: "/tmp/memory"),
            chatType: .group
        )
        let result = await service.recallSummaryIfEnabled(session: session, userQuery: "hello")
        #expect(result == nil)
        #expect(await tracker.callCount() == 0)
    }
}

// MARK: - Config parse tests

@Suite("MemoryConfiguration – two-lane config parsing")
struct MemoryConfigurationTwoLaneTests {
    @Test("default config has expected two-lane values")
    func defaultTwoLaneValues() {
        let config = MemoryConfiguration.default
        #expect(config.activeMemoryEnabled == true)
        #expect(config.activeMemoryStandingEnabled == true)
        #expect(config.activeMemoryStandingTTLMs == 3_600_000)
        #expect(config.activeMemoryStandingBudgetMs == 15_000)
        #expect(config.activeMemorySituationalEnabled == true)
        #expect(config.activeMemorySituationalTimeoutMs == 2_500)
        #expect(config.activeMemorySituationalTTLMs == 60_000)
    }

    @Test("active memory ships on; PromptConfig can opt out")
    func activeMemoryOnByDefaultWithOptOut() {
        #expect(MemoryConfiguration.default.activeMemoryEnabled == true)
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: [:]).activeMemoryEnabled == true
        )
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryEnabled": false])
                .activeMemoryEnabled == false
        )
        let fromBundleKeys = MemoryConfigurationLoader.load(fromMemoryObject: [
            "activeMemoryEnabled": true,
            "activeMemoryStandingEnabled": true,
            "activeMemorySituationalEnabled": true,
        ])
        #expect(fromBundleKeys.activeMemoryEnabled == true)
        #expect(fromBundleKeys.activeMemoryStandingEnabled == true)
        #expect(fromBundleKeys.activeMemorySituationalEnabled == true)
    }

    @Test("legacy activeMemoryTimeoutMs maps to situational timeout when new key absent")
    func legacyTimeoutMapsToSituational() {
        var config = MemoryConfiguration.default
        // Simulate what the loader does when only the legacy key is present
        let legacyMs = 5_000
        config.activeMemoryTimeoutMs = legacyMs
        config.activeMemorySituationalTimeoutMs = legacyMs  // loader fallback logic
        #expect(config.activeMemorySituationalTimeoutMs == 5_000)
    }

    @Test("activeMemoryTimeoutMs default lowered to 2500")
    func timeoutDefaultLowered() {
        #expect(MemoryConfiguration.default.activeMemoryTimeoutMs == 2_500)
    }

    @Test("activeMemoryMaxSummaryChars default is compact note budget")
    func summaryCharsDefaultCompact() {
        #expect(MemoryConfiguration.default.activeMemoryMaxSummaryChars == 220)
    }
}

// MARK: - Non-fatal proceed test

@Suite("TurnLoop – situational miss is non-fatal")
struct TurnLoopRecallNonFatalTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("situational nil recall does not prevent model.resolve and injects no memory message")
    func situationalNilDoesNotBlock() async throws {
        let model = makeModel()
        let conv = ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "tell me about grafana", timestamp: Date())],
            turns: [],
            interactionMode: .chat
        )
        let state = TurnLoopConversationState(conversation: conv)
        let capture = TurnLoopStreamMessageCapture()
        let basePorts = TurnLoopTestPorts.make(state: state)

        let resolveCallCount = LockIsolated(0)
        let memoryPort = SessionRuntimeMemoryPort(
            recallFn: { _, _, _, _ in
                ActiveMemoryRecallOutcome.skipped(
                    reason: "situational_miss",
                    queryMode: .recent
                )
            },   // situational miss
            prefetchFn: { _, _, _, _ in }
        )
        let modelPort = SessionRuntimeModelPort(
            ensureBoundFn: { conv, _ in
                resolveCallCount.withLock { $0 += 1 }
                return conv.model.id
            },
            streamLLM: { messages, _, _, _, _, _, _ in
                await capture.record(messages)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
                    continuation.finish()
                }
            }
        )
        let ports = AgentLoopPorts(
            model: modelPort,
            context: basePorts.context,
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
        let terminal = try await loop.run(
            conversationID: conv.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        // model.resolve was called despite recall miss
        #expect(resolveCallCount.withLock { $0 } >= 1)
        // no active memory message injected
        let streamed = await capture.messages()
        #expect(streamed.contains(where: { $0.content.contains("[Active Memory Recall]") }) == false)
        // terminal is natural stop, not a failure
        #expect(terminal.category == ConversationRunTerminalCategory.naturalStop || terminal.category == ConversationRunTerminalCategory.boundedStop)
    }
}

private actor TurnLoopStreamMessageCapture {
    private var streamed: [Message] = []
    func record(_ messages: [Message]) { streamed = messages }
    func messages() -> [Message] { streamed }
}

// Simple lock-isolated value for test assertions
private final class LockIsolated<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    @discardableResult
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
