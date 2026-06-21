import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor AttemptObservationCollector {
    var rows: [ModelCallAttemptObservation] = []

    func append(_ row: ModelCallAttemptObservation) {
        rows.append(row)
    }
}

/// Stub LLM that throws a queued sequence of errors then returns a canned response.
/// Useful for exercising ``RetryingLLM`` retry loops without touching real adapters.
private actor SequencedLLM: LLMProtocol {
    private var pendingErrors: [Error]
    private(set) var sendCallCount: Int = 0
    private(set) var generateImageCallCount: Int = 0
    private let response: LLMResponse
    private let imageResponse: ImageGenerationResponse

    init(errors: [Error],
         response: LLMResponse = LLMResponse(content: "ok", toolCalls: []),
         imageResponse: ImageGenerationResponse = ImageGenerationResponse(images: [])) {
        self.pendingErrors = errors
        self.response = response
        self.imageResponse = imageResponse
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }

    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { $0.finish() }
    }

    nonisolated func getModelName() -> String { "stub" }

    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        sendCallCount += 1
        if !pendingErrors.isEmpty {
            throw pendingErrors.removeFirst()
        }
        return response
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        generateImageCallCount += 1
        if !pendingErrors.isEmpty {
            throw pendingErrors.removeFirst()
        }
        return imageResponse
    }

    func observedSendCalls() -> Int { sendCallCount }
    func observedGenerateImageCalls() -> Int { generateImageCallCount }
}

/// Stub LLM that always throws on `send` until cancelled, so we can drive the cancellation
/// path through ``RetryingLLM``'s backoff sleep.
private actor InfiniteTransientLLM: LLMProtocol {
    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { $0.finish() }
    }
    nonisolated func getModelName() -> String { "infinite" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        throw LLMError.timeout
    }
    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw LLMError.timeout
    }
}

@Suite("RetryingLLM.send + generateImage backoff retries")
struct RetryingLLMSendTests {
    private static let fastPolicy = FailoverPolicy(
        maxRetries: 5,
        baseDelay: 0.001,
        maxDelay: 0.005,
        jitterFraction: 0.0
    )

    @Test("Transient errors retry until success; final response surfaces")
    func transientThenSuccess() async throws {
        let stub = SequencedLLM(errors: [LLMError.timeout, LLMError.rateLimitExceeded])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        let response = try await retry.send([], config: LLMRequestConfig())

        #expect(response.content == "ok")
        let calls = await stub.observedSendCalls()
        #expect(calls == 3)
    }

    @Test("Terminal first error throws immediately without retry")
    func terminalFirstNoRetry() async throws {
        let stub = SequencedLLM(errors: [LLMError.invalidRequest("bad")])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        await #expect(throws: LLMError.self) {
            _ = try await retry.send([], config: LLMRequestConfig())
        }
        let calls = await stub.observedSendCalls()
        #expect(calls == 1)
    }

    @Test("Transient errors past maxRetries throw last error; attempt count is maxRetries + 1")
    func transientExhausted() async throws {
        let policy = FailoverPolicy(maxRetries: 2, baseDelay: 0.001, maxDelay: 0.002, jitterFraction: 0.0)
        let stub = SequencedLLM(errors: [LLMError.timeout, LLMError.timeout, LLMError.timeout, LLMError.timeout])
        let retry = RetryingLLM(base: stub, policy: policy, logger: nil)

        await #expect(throws: LLMError.self) {
            _ = try await retry.send([], config: LLMRequestConfig())
        }
        let calls = await stub.observedSendCalls()
        #expect(calls == 3) // initial + 2 retries
    }

    @Test("CancellationError short-circuits the retry sleep")
    func cancellationInterruptsBackoff() async throws {
        // Slow policy so the wrapper is sleeping when we cancel.
        let policy = FailoverPolicy(maxRetries: 5, baseDelay: 1.0, maxDelay: 5.0, jitterFraction: 0.0)
        let stub = InfiniteTransientLLM()
        let retry = RetryingLLM(base: stub, policy: policy, logger: nil)

        let task = Task { () -> Result<LLMResponse, Error> in
            do {
                let response = try await retry.send([], config: LLMRequestConfig())
                return .success(response)
            } catch {
                return .failure(error)
            }
        }

        // Let the first attempt fail and the wrapper start sleeping.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let result = await task.value
        switch result {
        case .success:
            Issue.record("Expected cancellation to throw, got success")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    @Test("generateImage mirrors send: transient retries succeed")
    func generateImageRetries() async throws {
        let stub = SequencedLLM(errors: [LLMError.timeout])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        let response = try await retry.generateImage(ImageGenerationRequestConfig(prompt: "test"))

        #expect(response.images.isEmpty)
        let calls = await stub.observedGenerateImageCalls()
        #expect(calls == 2)
    }

    @Test("generateImage terminal error does not retry")
    func generateImageTerminalNoRetry() async throws {
        let stub = SequencedLLM(errors: [LLMError.unsupportedCapability(.imageGeneration)])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        await #expect(throws: LLMError.self) {
            _ = try await retry.generateImage(ImageGenerationRequestConfig(prompt: "test"))
        }
        let calls = await stub.observedGenerateImageCalls()
        #expect(calls == 1)
    }

    @Test("retry observer receives continued + terminal attempt outcomes")
    func retryObserverSeesAttemptOutcomes() async throws {
        let collector = AttemptObservationCollector()
        let policy = FailoverPolicy(maxRetries: 1, baseDelay: 0.001, maxDelay: 0.002, jitterFraction: 0.0)
        let stub = SequencedLLM(errors: [LLMError.timeout, LLMError.timeout])
        let modelID = UUID()
        let callID = UUID()
        let retry = RetryingLLM(
            base: stub,
            policy: policy,
            logger: nil,
            modelID: modelID,
            attemptObserver: { observation in
                await collector.append(observation)
            }
        )

        await ModelInvocationTaskContext.$callID.withValue(callID) {
            await #expect(throws: LLMError.self) {
                _ = try await retry.send([], config: LLMRequestConfig())
            }
        }

        let rows = await collector.rows
        let hasContinuedTimeout = rows.contains { row in
            row.kind == .retry && row.outcome == .continued && row.errorCode == "timeout"
        }
        let hasTerminalForCall = rows.contains { row in
            row.kind == .retry && row.outcome == .terminalFailure && row.callID == callID
        }
        #expect(rows.count == 2)
        #expect(hasContinuedTimeout)
        #expect(hasTerminalForCall)
    }
}

@Suite("RetryingLLM.backoffDelay (pure helper)")
struct RetryingLLMBackoffTests {
    @Test("Delay grows exponentially with attempt index (zero jitter)")
    func exponentialDoubling() {
        let policy = FailoverPolicy(maxRetries: 5, baseDelay: 0.1, maxDelay: 100.0, jitterFraction: 0.0)
        let d0 = RetryingLLM.backoffDelay(attempt: 0, policy: policy, randomUnit: 0.5)
        let d1 = RetryingLLM.backoffDelay(attempt: 1, policy: policy, randomUnit: 0.5)
        let d2 = RetryingLLM.backoffDelay(attempt: 2, policy: policy, randomUnit: 0.5)
        let d3 = RetryingLLM.backoffDelay(attempt: 3, policy: policy, randomUnit: 0.5)
        #expect(abs(d0 - 0.1) < 1e-9)
        #expect(abs(d1 - 0.2) < 1e-9)
        #expect(abs(d2 - 0.4) < 1e-9)
        #expect(abs(d3 - 0.8) < 1e-9)
    }

    @Test("Delay is capped at maxDelay")
    func cappedAtMaxDelay() {
        let policy = FailoverPolicy(maxRetries: 10, baseDelay: 1.0, maxDelay: 4.0, jitterFraction: 0.0)
        let d0 = RetryingLLM.backoffDelay(attempt: 0, policy: policy, randomUnit: 0.5)
        let d3 = RetryingLLM.backoffDelay(attempt: 3, policy: policy, randomUnit: 0.5)
        let d10 = RetryingLLM.backoffDelay(attempt: 10, policy: policy, randomUnit: 0.5)
        #expect(d0 == 1.0)
        #expect(d3 == 4.0) // 8 capped to 4
        #expect(d10 == 4.0) // 1024 capped to 4
    }

    @Test("Jitter at randomUnit=0 is 1 - jitterFraction; at randomUnit=1 is 1 + jitterFraction")
    func jitterEndpoints() {
        let policy = FailoverPolicy(maxRetries: 3, baseDelay: 1.0, maxDelay: 10.0, jitterFraction: 0.25)
        let low = RetryingLLM.backoffDelay(attempt: 0, policy: policy, randomUnit: 0.0)
        let mid = RetryingLLM.backoffDelay(attempt: 0, policy: policy, randomUnit: 0.5)
        let high = RetryingLLM.backoffDelay(attempt: 0, policy: policy, randomUnit: 1.0)
        #expect(abs(low - 0.75) < 1e-9)
        #expect(abs(mid - 1.0) < 1e-9)
        #expect(abs(high - 1.25) < 1e-9)
    }

    @Test("jitterFraction = 0 yields deterministic delay regardless of randomUnit")
    func zeroJitterIsDeterministic() {
        let policy = FailoverPolicy(maxRetries: 3, baseDelay: 0.5, maxDelay: 10.0, jitterFraction: 0.0)
        let a = RetryingLLM.backoffDelay(attempt: 1, policy: policy, randomUnit: 0.0)
        let b = RetryingLLM.backoffDelay(attempt: 1, policy: policy, randomUnit: 1.0)
        #expect(a == b)
        #expect(abs(a - 1.0) < 1e-9)
    }

    @Test("Negative attempt is clamped to 0")
    func negativeAttemptClamped() {
        let policy = FailoverPolicy(maxRetries: 3, baseDelay: 0.5, maxDelay: 10.0, jitterFraction: 0.0)
        let d = RetryingLLM.backoffDelay(attempt: -3, policy: policy, randomUnit: 0.5)
        #expect(abs(d - 0.5) < 1e-9)
    }

    @Test("retryDelay prefers provider retry-after hint over computed backoff")
    func retryDelayPrefersRetryAfterHint() {
        let policy = FailoverPolicy(maxRetries: 3, baseDelay: 0.5, maxDelay: 10.0, jitterFraction: 0.0)
        let hinted = RetryAfterRateLimitError(retryAfterSeconds: 7.0)
        let delay = RetryingLLM.retryDelay(for: hinted, attempt: 1, policy: policy)
        #expect(abs(delay - 7.0) < 1e-9)
    }

    @Test("retryDelay falls back to computed backoff when no hint")
    func retryDelayFallsBackToBackoff() {
        let policy = FailoverPolicy(maxRetries: 3, baseDelay: 0.5, maxDelay: 10.0, jitterFraction: 0.0)
        let delay = RetryingLLM.retryDelay(for: LLMError.timeout, attempt: 1, policy: policy)
        #expect(abs(delay - 1.0) < 1e-9)
    }
}
