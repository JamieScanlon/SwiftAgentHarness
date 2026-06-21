import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Blocks ``acquire`` until ``unblock()`` — exercise ``ModelInvocationPhase/queued`` before slot grant.
private actor BlockingModelCallScheduler: ModelCallScheduling {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var acquiredPriorities: [ModelRequestPriority] = []
    private(set) var releaseCount: Int = 0

    func acquire(for modelID: UUID, priority: ModelRequestPriority) async {
        acquiredPriorities.append(priority)
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release(for modelID: UUID) async {
        releaseCount += 1
    }

    func inFlightCount(for modelID: UUID) async -> Int { 0 }

    func unblockOneWaiter() {
        guard !waiters.isEmpty else { return }
        let c = waiters.removeFirst()
        c.resume()
    }
}

private actor ImmediateModelCallScheduler: ModelCallScheduling {
    private(set) var acquireCount: Int = 0
    private(set) var releaseCount: Int = 0

    func acquire(for modelID: UUID, priority: ModelRequestPriority) async {
        acquireCount += 1
    }

    func release(for modelID: UUID) async {
        releaseCount += 1
    }

    func inFlightCount(for modelID: UUID) async -> Int { 0 }
}

private struct OneShotCompleteLLM: LLMProtocol {
    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }

    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { $0.finish() }
    }

    nonisolated func getModelName() -> String { "test" }

    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        LLMResponse(content: "ok", toolCalls: [])
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.complete(LLMResponse(content: "ok", toolCalls: [])))
            continuation.finish()
        }
    }

    nonisolated func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private struct FailingSendLLM: LLMProtocol {
    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }

    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { $0.finish() }
    }

    nonisolated func getModelName() -> String { "fail" }

    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        throw LLMError.invalidRequest("synthetic failure")
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMError.invalidRequest("synthetic failure"))
        }
    }

    nonisolated func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor PhaseCollector {
    var phases: [ModelInvocationPhase] = []
    func append(_ p: ModelInvocationPhase) {
        phases.append(p)
    }
}

@Suite("SchedulingLLM queued phase", .serialized)
struct SchedulingLLMQueuedPhaseTests {
    @Test("Reports queued while scheduler blocks, then proceeds after unblock")
    func queuedThenDispatching() async throws {
        let scheduler = BlockingModelCallScheduler()
        let collector = PhaseCollector()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await collector.append(payload.phase)
        }
        let modelID = UUID()
        let inner = LifecycleReportingLLM(
            baseLLM: OneShotCompleteLLM(),
            modelID: modelID,
            coordinator: coordinator
        )
        let scheduled = SchedulingLLM(
            baseLLM: inner,
            scheduler: scheduler,
            modelID: modelID,
            coordinator: coordinator
        )

        let stream = scheduled.stream([], config: LLMRequestConfig())

        let drain = Task {
            for try await _ in stream {}
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        let midQueued = await collector.phases
        #expect(midQueued.first == .queued)

        await scheduler.unblockOneWaiter()

        try await drain.value
        let phases = await collector.phases
        #expect(phases.contains(.dispatching))
        #expect(phases.contains(.done))

        let priorities = await scheduler.acquiredPriorities
        #expect(priorities == [.foreground])
    }

    @Test("Forwards .background priority to scheduler when opted in")
    func backgroundPriorityForwarded() async throws {
        let scheduler = BlockingModelCallScheduler()
        let modelID = UUID()
        let scheduled = SchedulingLLM(
            baseLLM: OneShotCompleteLLM(),
            scheduler: scheduler,
            modelID: modelID,
            priority: .background
        )

        let stream = scheduled.stream([], config: LLMRequestConfig())
        let drain = Task {
            for try await _ in stream {}
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        await scheduler.unblockOneWaiter()
        try await drain.value

        let priorities = await scheduler.acquiredPriorities
        #expect(priorities == [.background])
    }

    @Test("Releases scheduler slot when send throws")
    func releaseOnSendError() async throws {
        let scheduler = ImmediateModelCallScheduler()
        let scheduled = SchedulingLLM(
            baseLLM: FailingSendLLM(),
            scheduler: scheduler,
            modelID: UUID(),
            priority: .foreground
        )
        await #expect(throws: Error.self) {
            _ = try await scheduled.send([], config: LLMRequestConfig())
        }
        #expect(await scheduler.acquireCount == 1)
        #expect(await scheduler.releaseCount == 1)
    }
}
