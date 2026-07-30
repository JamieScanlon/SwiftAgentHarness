import Foundation
import Logging
import SwiftAgentKit

enum RetryingLLMFactory {
    static func wrap(
        baseLLM: any LLMProtocol,
        policy: FailoverPolicy,
        logger: Logger?,
        modelID: UUID? = nil,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)? = nil
    ) -> any LLMProtocol {
        guard policy.maxRetries > 0 else { return baseLLM }
        return RetryingLLM(
            base: baseLLM,
            policy: policy,
            logger: logger,
            modelID: modelID,
            attemptObserver: attemptObserver
        )
    }
}

/// Same-binding retries with exponential backoff + jitter (Phase 6 failover migrate slice).
///
/// - `send` / `generateImage`: classify each thrown error via ``TransientErrorClassifier``;
///   on `.transient` with attempts remaining, sleep ``backoffDelay(attempt:policy:)`` and
///   retry. `.terminal` errors (and ``CancellationError``) propagate immediately.
/// - `stream`: pre-first-chunk-gated. The wrapper retries only when the inner stream
///   throws **before** any partial reaches the consumer; once a partial is yielded the
///   wrapper cannot retry without duplicating output, so the error surfaces.
///
/// Constructed only when ``FailoverPolicy/maxRetries`` `> 0` (see ``RetryingLLMFactory``);
/// when retries are disabled this type is bypassed entirely and there is no behavioral
/// or performance overhead.
struct RetryingLLM: LLMProtocol, AdapterAuthProbing {
    let base: any LLMProtocol
    let policy: FailoverPolicy
    let logger: Logger?
    let modelID: UUID?
    let attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?

    init(
        base: any LLMProtocol,
        policy: FailoverPolicy,
        logger: Logger?,
        modelID: UUID? = nil,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)? = nil
    ) {
        self.base = base
        self.policy = policy
        self.logger = logger
        self.modelID = modelID
        self.attemptObserver = attemptObserver
    }

    var currentState: LLMRuntimeState { base.currentState }

    var stateUpdates: AsyncStream<LLMRuntimeState> { base.stateUpdates }

    func getModelName() -> String { base.getModelName() }

    func getCapabilities() -> [LLMCapability] { base.getCapabilities() }

    func getRequestFeatures() -> ModelRequestFeatures { base.getRequestFeatures() }

    func validateAuth() async -> Bool {
        guard let probe = base as? any AdapterAuthProbing else { return true }
        return await probe.validateAuth()
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        try await runWithBackoff(label: "send") {
            try await base.send(messages, config: config)
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        try await runWithBackoff(label: "generateImage") {
            try await base.generateImage(config)
        }
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    var firstYielded = false
                    do {
                        for try await result in base.stream(messages, config: config) {
                            firstYielded = true
                            continuation.yield(result)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        // Once the consumer has seen any partial we can't safely re-issue
                        // the call without duplicating output. Likewise, terminal errors
                        // and an exhausted attempt budget propagate immediately.
                        if firstYielded
                            || TransientErrorClassifier.classify(error) == .terminal
                            || attempt >= policy.maxRetries {
                            let surfaced = Self.annotated(error, attempts: attempt + 1)
                            await emitAttempt(kind: .retry, outcome: .terminalFailure, error: surfaced)
                            continuation.finish(throwing: surfaced)
                            return
                        }
                        let delay = Self.retryDelay(for: error, attempt: attempt, policy: policy)
                        await emitAttempt(kind: .retry, outcome: .continued, error: error, latencyMs: delay * 1000)
                        logger?.warning("LLM stream transient retry \(attempt + 1)/\(policy.maxRetries) (pre-first-chunk): \(error) — sleeping \(delay)s")
                        do {
                            try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                        } catch {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        attempt += 1
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Helpers

    /// Shared retry loop for non-streaming calls (`send`, `generateImage`).
    /// Loop exit is via `return` (success) or `throw` (terminal / exhausted / cancelled).
    private func runWithBackoff<T>(label: String, work: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let decision = TransientErrorClassifier.classify(error)
                guard decision == .transient, attempt < policy.maxRetries else {
                    let surfaced = Self.annotated(error, attempts: attempt + 1)
                    await emitAttempt(kind: .retry, outcome: .terminalFailure, error: surfaced)
                    throw surfaced
                }
                let delay = Self.retryDelay(for: error, attempt: attempt, policy: policy)
                await emitAttempt(kind: .retry, outcome: .continued, error: error, latencyMs: delay * 1000)
                logger?.warning("LLM \(label) transient retry \(attempt + 1)/\(policy.maxRetries): \(error) — sleeping \(delay)s")
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                } catch {
                    throw CancellationError()
                }
                attempt += 1
            }
        }
    }

    /// Lets an error restate itself with the attempt count that produced it. Annotating rather
    /// than wrapping keeps the concrete type visible to the `as?` checks and classifiers
    /// downstream; errors that opt out are returned untouched.
    private static func annotated(_ error: Error, attempts: Int) -> Error {
        (error as? any AttemptAnnotatableError)?.annotatedWithAttempts(attempts) ?? error
    }

    /// Pure exponential-backoff-with-jitter helper. Exposed `internal` (and `static`) so
    /// tests can exercise the math deterministically by passing a fixed `randomUnit`.
    ///
    /// Returns `min(policy.maxDelay, baseDelay * 2^attempt * (1 + (2*randomUnit - 1) * jitterFraction))`,
    /// clamped to a non-negative interval.
    static func backoffDelay(
        attempt: Int,
        policy: FailoverPolicy,
        randomUnit: Double = .random(in: 0..<1)
    ) -> TimeInterval {
        let safeAttempt = max(0, attempt)
        let exponential = policy.baseDelay * pow(2.0, Double(safeAttempt))
        let capped = min(policy.maxDelay, exponential)
        let jitterMultiplier = 1.0 + (randomUnit * 2.0 - 1.0) * policy.jitterFraction
        let withJitter = capped * max(0.0, jitterMultiplier)
        return min(policy.maxDelay, max(0.0, withJitter))
    }

    /// Retry delay preference: provider `Retry-After` (when surfaced) overrides generic backoff.
    static func retryDelay(for error: Error, attempt: Int, policy: FailoverPolicy) -> TimeInterval {
        if let hinted = TransientErrorClassifier.retryAfterSeconds(error) {
            return max(0, hinted)
        }
        return backoffDelay(attempt: attempt, policy: policy)
    }

    /// Converts seconds to nanoseconds for `Task.sleep`, clamping non-finite or negative
    /// values to `0` so we never request an invalid sleep duration.
    static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let scaled = seconds * 1_000_000_000
        if scaled >= Double(UInt64.max) { return UInt64.max }
        return UInt64(scaled)
    }

    private func emitAttempt(
        kind: ModelCallAttemptKind,
        outcome: ModelCallAttemptOutcome,
        error: Error?,
        latencyMs: Double? = nil
    ) async {
        guard let modelID, let attemptObserver else { return }
        await attemptObserver(
            ModelCallAttemptObservation(
                modelID: modelID,
                callID: ModelInvocationTaskContext.callID,
                kind: kind,
                outcome: outcome,
                errorClass: error.map(Self.errorClass),
                errorCode: error.flatMap(Self.errorCode),
                latencyMs: latencyMs
            )
        )
    }

    private static func errorClass(_ error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        return TransientErrorClassifier.classify(error) == .transient ? "transient" : "terminal"
    }

    private static func errorCode(_ error: Error) -> String? {
        if let llmError = error as? LLMError {
            switch llmError {
            case .timeout:
                return "timeout"
            case .rateLimitExceeded:
                return "rate_limit"
            case .authenticationFailed:
                return "authentication_failed"
            case .modelNotFound:
                return "model_not_found"
            case .invalidRequest:
                return "invalid_request"
            case .networkError:
                return "network_error"
            case .unsupportedCapability:
                return "unsupported_capability"
            default:
                return "other_llm_error"
            }
        }
        return nil
    }
}
