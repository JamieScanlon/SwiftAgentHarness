import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Yields one streaming partial, then loops until cancelled — models a long-running provider.
private actor HangingAfterFirstChunkLLM: LLMProtocol {
    private(set) var postFirstYieldIterations = 0
    private(set) var producerFinished = false

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }

    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { $0.finish() }
    }

    nonisolated func getModelName() -> String { "hanging" }

    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        LLMResponse(content: "ignored", toolCalls: [])
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            let llm = self
            let task = Task {
                continuation.yield(.stream(LLMResponse(content: "partial", toolCalls: [])))
                while !Task.isCancelled {
                    await llm.recordPostFirstIteration()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                await llm.markProducerFinished()
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw LLMError.unsupportedCapability(.imageGeneration)
    }

    func recordPostFirstIteration() {
        postFirstYieldIterations += 1
    }

    func markProducerFinished() {
        producerFinished = true
    }
}

private actor TrackingModelCallScheduler: ModelCallScheduling {
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0

    func acquire(for modelID: UUID, priority: ModelRequestPriority) async {
        acquireCount += 1
    }

    func release(for modelID: UUID) async {
        releaseCount += 1
    }

    func inFlightCount(for modelID: UUID) async -> Int { 0 }
}

private actor BlockingModelCallScheduler: ModelCallScheduling {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var releaseCount = 0

    func acquire(for modelID: UUID, priority: ModelRequestPriority) async {
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
        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

@Suite("SchedulingLLM stream cancellation", .serialized)
struct SchedulingLLMStreamCancellationTests {
    @Test("Releases pool slot when consumer cancels mid-stream")
    func releasesPoolSlotOnCancel() async throws {
        let scheduler = ModelCallScheduler(maxConcurrent: 1)
        let modelID = UUID()
        let inner = HangingAfterFirstChunkLLM()
        let scheduled = SchedulingLLM(
            baseLLM: inner,
            scheduler: scheduler,
            modelID: modelID
        )

        let stream1 = scheduled.stream([], config: LLMRequestConfig())
        let consumer1 = Task {
            var receivedFirst = false
            for try await result in stream1 {
                if case .stream = result {
                    receivedFirst = true
                }
                if receivedFirst {
                    continue
                }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        consumer1.cancel()
        _ = try? await consumer1.value

        try await Task.sleep(nanoseconds: 100_000_000)
        let healthAfterCancel = await scheduler.poolHealthSnapshot()
        #expect(healthAfterCancel.inFlight == 0)

        let stream2 = scheduled.stream([], config: LLMRequestConfig())
        let consumer2 = Task {
            var receivedFirst = false
            for try await result in stream2 {
                if case .stream = result {
                    receivedFirst = true
                }
                if receivedFirst {
                    continue
                }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let healthDuringSecond = await scheduler.poolHealthSnapshot()
        #expect(healthDuringSecond.inFlight == 1)
        consumer2.cancel()
        _ = try? await consumer2.value
    }

    @Test("Stops draining upstream and releases scheduler slot on cancel")
    func stopsUpstreamDrainingOnCancel() async throws {
        let scheduler = TrackingModelCallScheduler()
        let modelID = UUID()
        let inner = HangingAfterFirstChunkLLM()
        let lifecycle = LifecycleReportingLLM(
            baseLLM: inner,
            modelID: modelID,
            coordinator: ModelInvocationCoordinator { _, _ in }
        )
        let scheduled = SchedulingLLM(
            baseLLM: lifecycle,
            scheduler: scheduler,
            modelID: modelID
        )

        let stream = scheduled.stream([], config: LLMRequestConfig())
        let consumer = Task {
            var receivedFirst = false
            for try await result in stream {
                if case .stream = result {
                    receivedFirst = true
                }
                if receivedFirst {
                    continue
                }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        consumer.cancel()
        _ = try? await consumer.value

        try await Task.sleep(nanoseconds: 100_000_000)
        let iterationsAfterCancel = await inner.postFirstYieldIterations
        #expect(iterationsAfterCancel <= 30)
        #expect(await scheduler.acquireCount == 1)
        #expect(await scheduler.releaseCount == 1)
    }

    @Test("Cancel while queued does not acquire a scheduler slot")
    func cancelWhileQueuedDoesNotAcquire() async throws {
        let scheduler = BlockingModelCallScheduler()
        let modelID = UUID()
        let scheduled = SchedulingLLM(
            baseLLM: HangingAfterFirstChunkLLM(),
            scheduler: scheduler,
            modelID: modelID
        )

        let stream = scheduled.stream([], config: LLMRequestConfig())
        let consumer = Task {
            for try await _ in stream {}
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        consumer.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await scheduler.releaseCount == 0)
    }
}
