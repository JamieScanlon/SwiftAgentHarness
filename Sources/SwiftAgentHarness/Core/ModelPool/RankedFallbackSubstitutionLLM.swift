import Foundation
import Logging
import SwiftAgentKit

/// Cross-model ranked fallback wrapper.
///
/// Expects each candidate to already include same-model retry/binding failover behavior.
/// This wrapper only handles advancing from one ranked model candidate to the next.
struct RankedFallbackSubstitutionLLM: LLMProtocol {
    struct Candidate: Sendable {
        let modelID: UUID
        let label: String
        let llm: any LLMProtocol
    }

    let candidates: [Candidate]
    let logger: Logger?
    let attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?

    init(
        candidates: [Candidate],
        logger: Logger? = nil,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)? = nil
    ) {
        self.candidates = candidates
        self.logger = logger
        self.attemptObserver = attemptObserver
    }

    var currentState: LLMRuntimeState {
        candidates.first?.llm.currentState ?? .idle(.ready)
    }

    var stateUpdates: AsyncStream<LLMRuntimeState> {
        candidates.first?.llm.stateUpdates ?? AsyncStream { continuation in
            continuation.finish()
        }
    }

    func getModelName() -> String {
        candidates.first?.llm.getModelName() ?? "unbound-model"
    }

    func getCapabilities() -> [LLMCapability] {
        candidates.first?.llm.getCapabilities() ?? []
    }

    func getRequestFeatures() -> ModelRequestFeatures {
        candidates.first?.llm.getRequestFeatures() ?? .unknown
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let logicalRequestID = ModelInvocationTaskContext.logicalRequestID ?? UUID()
        return try await ModelInvocationTaskContext.$logicalRequestID.withValue(logicalRequestID) {
            try await withModelAttempts(operation: "send") { candidate in
                try await candidate.llm.send(messages, config: config)
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let logicalRequestID = ModelInvocationTaskContext.logicalRequestID ?? UUID()
        return try await ModelInvocationTaskContext.$logicalRequestID.withValue(logicalRequestID) {
            try await withModelAttempts(operation: "generateImage") { candidate in
                try await candidate.llm.generateImage(config)
            }
        }
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let logicalRequestID = ModelInvocationTaskContext.logicalRequestID ?? UUID()
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard !candidates.isEmpty else {
                    continuation.finish(throwing: LLMError.modelNotFound("No ranked model candidates available"))
                    return
                }
                for (index, candidate) in candidates.enumerated() {
                    var firstYielded = false
                    do {
                        let upstream = ModelInvocationTaskContext.$logicalRequestID.withValue(logicalRequestID) {
                            candidate.llm.stream(messages, config: config)
                        }
                        for try await event in upstream {
                            firstYielded = true
                            continuation.yield(event)
                        }
                        if index > 0 {
                            await emitAttempt(
                                candidate: candidate,
                                outcome: .succeeded,
                                error: nil
                            )
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        let canAdvance = !firstYielded
                            && index < candidates.count - 1
                            && SubstitutionFallbackClassifier.shouldTryNextModel(error)
                        if canAdvance {
                            await emitAttempt(
                                candidate: candidate,
                                outcome: .continued,
                                error: error
                            )
                            logger?.warning("Model substitution stream fallback from \(candidate.label) due to pre-first-chunk error: \(error)")
                            continue
                        }
                        await emitAttempt(
                            candidate: candidate,
                            outcome: .terminalFailure,
                            error: error
                        )
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func withModelAttempts<T>(
        operation: String,
        _ work: @escaping @Sendable (Candidate) async throws -> T
    ) async throws -> T {
        guard !candidates.isEmpty else {
            throw LLMError.modelNotFound("No ranked model candidates available")
        }
        var lastError: Error?
        for (index, candidate) in candidates.enumerated() {
            do {
                if index > 0 {
                    await emitAttempt(
                        candidate: candidate,
                        outcome: .succeeded,
                        error: nil
                    )
                }
                return try await work(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let canAdvance = index < candidates.count - 1
                    && SubstitutionFallbackClassifier.shouldTryNextModel(error)
                if canAdvance {
                    await emitAttempt(
                        candidate: candidate,
                        outcome: .continued,
                        error: error
                    )
                    logger?.warning("Model substitution \(operation) fallback from \(candidate.label) due to error: \(error)")
                    continue
                }
                await emitAttempt(
                    candidate: candidate,
                    outcome: .terminalFailure,
                    error: error
                )
                throw error
            }
        }
        throw lastError ?? LLMError.modelNotFound("No ranked model candidates available")
    }

    private func emitAttempt(
        candidate: Candidate,
        outcome: ModelCallAttemptOutcome,
        error: Error?
    ) async {
        guard let attemptObserver else { return }
        await attemptObserver(
            ModelCallAttemptObservation(
                modelID: candidate.modelID,
                callID: ModelInvocationTaskContext.callID,
                kind: .modelSubstitution,
                outcome: outcome,
                errorClass: error.map(Self.errorClass),
                errorCode: error.flatMap(Self.errorCode),
                targetModelID: candidate.modelID
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

enum SubstitutionFallbackClassifier {
    static func shouldTryNextModel(_ error: Error) -> Bool {
        BindingFailoverClassifier.classify(error) == .tryNextBinding
    }
}

