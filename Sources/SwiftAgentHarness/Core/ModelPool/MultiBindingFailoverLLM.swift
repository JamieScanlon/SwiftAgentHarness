import Foundation
import Logging
import SwiftAgentKit

/// Cross-binding failover for one logical model entry.
///
/// Each binding attempt delegates same-binding retry behavior to the provided LLM constructor
/// (typically ``RetryingLLMFactory`` wrapping the adapter for that binding).
struct MultiBindingFailoverLLM: LLMProtocol {
    let bindings: [ProviderBinding]
    let makeBindingLLM: @Sendable (ProviderBinding) -> any LLMProtocol
    let logger: Logger?
    let modelID: UUID?
    let attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?

    init(
        bindings: [ProviderBinding],
        makeBindingLLM: @escaping @Sendable (ProviderBinding) -> any LLMProtocol,
        logger: Logger? = nil,
        modelID: UUID? = nil,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)? = nil
    ) {
        self.bindings = bindings.sorted { $0.priority < $1.priority }
        self.makeBindingLLM = makeBindingLLM
        self.logger = logger
        self.modelID = modelID
        self.attemptObserver = attemptObserver
    }

    var currentState: LLMRuntimeState {
        guard let first = bindings.first else { return .idle(.ready) }
        return makeBindingLLM(first).currentState
    }

    var stateUpdates: AsyncStream<LLMRuntimeState> {
        guard let first = bindings.first else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return makeBindingLLM(first).stateUpdates
    }

    func getModelName() -> String {
        guard let first = bindings.first else { return "unbound-model" }
        return makeBindingLLM(first).getModelName()
    }

    func getCapabilities() -> [LLMCapability] {
        guard let first = bindings.first else { return [] }
        return makeBindingLLM(first).getCapabilities()
    }

    func getRequestFeatures() -> ModelRequestFeatures {
        guard let first = bindings.first else { return .unknown }
        return makeBindingLLM(first).getRequestFeatures()
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        try await withBindingAttempts(operation: "send") { llm in
            try await llm.send(messages, config: config)
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        try await withBindingAttempts(operation: "generateImage") { llm in
            try await llm.generateImage(config)
        }
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard !bindings.isEmpty else {
                    continuation.finish(throwing: LLMError.modelNotFound("No provider bindings available"))
                    return
                }

                for (index, binding) in bindings.enumerated() {
                    let llm = makeBindingLLM(binding)
                    if !(await authPermitsAttempt(llm: llm, binding: binding)) {
                        let canAdvance = index < bindings.count - 1
                        await emitAttempt(
                            binding: binding,
                            kind: .authProbeSkip,
                            outcome: canAdvance ? .skipped : .terminalFailure,
                            error: LLMError.authenticationFailed
                        )
                        if canAdvance { continue }
                        continuation.finish(throwing: LLMError.authenticationFailed)
                        return
                    }
                    var firstYielded = false
                    do {
                        for try await result in llm.stream(messages, config: config) {
                            firstYielded = true
                            continuation.yield(result)
                        }
                        if index > 0 {
                            await emitAttempt(
                                binding: binding,
                                kind: .bindingFailover,
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
                            && index < bindings.count - 1
                            && BindingFailoverClassifier.classify(error, providerID: binding.providerId) == .tryNextBinding
                        if canAdvance {
                            await emitAttempt(
                                binding: binding,
                                kind: .bindingFailover,
                                outcome: .continued,
                                error: error
                            )
                            logger?.warning("LLM stream binding failover from \(binding.providerId):\(binding.endpointModelId) after pre-first-chunk error: \(error)")
                            continue
                        }
                        await emitAttempt(
                            binding: binding,
                            kind: .bindingFailover,
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

    private func withBindingAttempts<T>(
        operation: String,
        _ work: @escaping @Sendable (any LLMProtocol) async throws -> T
    ) async throws -> T {
        guard !bindings.isEmpty else {
            throw LLMError.modelNotFound("No provider bindings available")
        }
        var lastError: Error?
        for (index, binding) in bindings.enumerated() {
            let llm = makeBindingLLM(binding)
            if !(await authPermitsAttempt(llm: llm, binding: binding)) {
                lastError = LLMError.authenticationFailed
                let canAdvance = index < bindings.count - 1
                await emitAttempt(
                    binding: binding,
                    kind: .authProbeSkip,
                    outcome: canAdvance ? .skipped : .terminalFailure,
                    error: LLMError.authenticationFailed
                )
                if canAdvance { continue }
                throw LLMError.authenticationFailed
            }
            do {
                let result = try await work(llm)
                if index > 0 {
                    await emitAttempt(
                        binding: binding,
                        kind: .bindingFailover,
                        outcome: .succeeded,
                        error: nil
                    )
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let canAdvance = index < bindings.count - 1
                    && BindingFailoverClassifier.classify(error, providerID: binding.providerId) == .tryNextBinding
                if canAdvance {
                    await emitAttempt(
                        binding: binding,
                        kind: .bindingFailover,
                        outcome: .continued,
                        error: error
                    )
                    logger?.warning("LLM \(operation) binding failover from \(binding.providerId):\(binding.endpointModelId) due to error: \(error)")
                    continue
                }
                await emitAttempt(
                    binding: binding,
                    kind: .bindingFailover,
                    outcome: .terminalFailure,
                    error: error
                )
                throw error
            }
        }
        throw lastError ?? LLMError.modelNotFound("No provider bindings available")
    }

    private func authPermitsAttempt(llm: any LLMProtocol, binding: ProviderBinding) async -> Bool {
        guard let probe = llm as? any AdapterAuthProbing else { return true }
        let valid = await probe.validateAuth()
        if !valid {
            logger?.warning("LLM binding auth probe failed for \(binding.providerId):\(binding.endpointModelId); skipping binding")
        }
        return valid
    }

    private func emitAttempt(
        binding: ProviderBinding,
        kind: ModelCallAttemptKind,
        outcome: ModelCallAttemptOutcome,
        error: Error?
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
                providerID: binding.providerId,
                endpointModelID: binding.endpointModelId
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

