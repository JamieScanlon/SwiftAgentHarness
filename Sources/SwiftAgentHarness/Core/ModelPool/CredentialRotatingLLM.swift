import Foundation
import Logging
import SwiftAgentKit

private actor CredentialRotationState {
    var roundRobinCursor: Int = 0
    private var usageCounts: [String: Int] = [:]

    func recordUse(credentialID: String) {
        usageCounts[credentialID, default: 0] += 1
    }

    func roundRobinCursorValue() -> Int { roundRobinCursor }

    func setRoundRobinCursor(_ value: Int) {
        roundRobinCursor = value
    }

    func snapshotUsageCounts() -> [String: Int] {
        usageCounts
    }
}

/// Intra-binding credential rotation for a single `(provider, authProfile)` pool.
struct CredentialRotatingLLM: LLMProtocol {
    let binding: ProviderBinding
    let credentialPool: [AuthProfile]
    let rotationStrategy: AuthProfileRotationStrategy
    let billingCooldown: TimeInterval
    let rateLimitCooldown: TimeInterval
    let cooldownRegistry: AuthProfileCooldownRegistry
    let makeCredentialLLM: @Sendable (AuthProfile) -> any LLMProtocol
    let logger: Logger?
    let modelID: UUID?
    let attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?

    private let rotationState = CredentialRotationState()

    init(
        binding: ProviderBinding,
        credentialPool: [AuthProfile],
        rotationStrategy: AuthProfileRotationStrategy = .fillFirst,
        billingCooldown: TimeInterval = 3600,
        rateLimitCooldown: TimeInterval = 900,
        cooldownRegistry: AuthProfileCooldownRegistry,
        makeCredentialLLM: @escaping @Sendable (AuthProfile) -> any LLMProtocol,
        logger: Logger? = nil,
        modelID: UUID? = nil,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)? = nil
    ) {
        self.binding = binding
        self.credentialPool = credentialPool
        self.rotationStrategy = rotationStrategy
        self.billingCooldown = billingCooldown
        self.rateLimitCooldown = rateLimitCooldown
        self.cooldownRegistry = cooldownRegistry
        self.makeCredentialLLM = makeCredentialLLM
        self.logger = logger
        self.modelID = modelID
        self.attemptObserver = attemptObserver
    }

    var currentState: LLMRuntimeState {
        guard let first = credentialPool.first else { return .idle(.ready) }
        return makeCredentialLLM(first).currentState
    }

    var stateUpdates: AsyncStream<LLMRuntimeState> {
        guard let first = credentialPool.first else {
            return AsyncStream { $0.finish() }
        }
        return makeCredentialLLM(first).stateUpdates
    }

    func getModelName() -> String {
        binding.endpointModelId
    }

    func getCapabilities() -> [LLMCapability] {
        guard let first = credentialPool.first else { return [] }
        return makeCredentialLLM(first).getCapabilities()
    }

    func getRequestFeatures() -> ModelRequestFeatures {
        guard let first = credentialPool.first else { return .unknown }
        return makeCredentialLLM(first).getRequestFeatures()
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        try await withCredentialAttempts(operation: "send") { llm in
            try await llm.send(messages, config: config)
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        try await withCredentialAttempts(operation: "generateImage") { llm in
            try await llm.generateImage(config)
        }
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var excludeIDs: Set<String> = []
                var lastError: Error?
                while true {
                    guard let selection = await nextSelection(excludeIDs: excludeIDs) else {
                        continuation.finish(throwing: lastError ?? LLMError.authenticationFailed)
                        return
                    }
                    let credential = selection.credential
                    await rotationState.recordUse(credentialID: credential.id)
                    let llm = makeCredentialLLM(credential)
                    var firstYielded = false
                    do {
                        for try await result in llm.stream(messages, config: config) {
                            firstYielded = true
                            continuation.yield(result)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        lastError = error
                        let shouldRotate = await shouldRotateCredential(for: error)
                        if shouldRotate, !firstYielded {
                            await markCooldown(for: credential, error: error)
                            await emitAttempt(
                                credential: credential,
                                outcome: .continued,
                                error: error
                            )
                            excludeIDs.insert(credential.id)
                            logger?.warning(
                                "LLM stream credential rotation for \(binding.providerId):\(binding.endpointModelId) credential \(credential.id)"
                            )
                            continue
                        }
                        await emitAttempt(
                            credential: credential,
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

    private func withCredentialAttempts<T>(
        operation: String,
        _ work: @escaping @Sendable (any LLMProtocol) async throws -> T
    ) async throws -> T {
        var excludeIDs: Set<String> = []
        var lastError: Error?
        while true {
            guard let selection = await nextSelection(excludeIDs: excludeIDs) else {
                throw lastError ?? LLMError.authenticationFailed
            }
            let credential = selection.credential
            await rotationState.recordUse(credentialID: credential.id)
            let llm = makeCredentialLLM(credential)
            do {
                return try await work(llm)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if await shouldRotateCredential(for: error) {
                    await markCooldown(for: credential, error: error)
                    await emitAttempt(
                        credential: credential,
                        outcome: .continued,
                        error: error
                    )
                    excludeIDs.insert(credential.id)
                    logger?.warning(
                        "LLM \(operation) credential rotation for \(binding.providerId):\(binding.endpointModelId) credential \(credential.id)"
                    )
                    continue
                }
                await emitAttempt(
                    credential: credential,
                    outcome: .terminalFailure,
                    error: error
                )
                throw error
            }
        }
    }

    private func nextSelection(excludeIDs: Set<String>) async -> AuthProfileSelector.SelectionResult? {
        let cursor = await rotationState.roundRobinCursorValue()
        var cooldownStates: [String: AuthProfileCooldownState] = [:]
        for profile in credentialPool {
            cooldownStates[profile.id] = await cooldownRegistry.state(forKey: profile.id)
        }
        let usageCounts = await rotationState.snapshotUsageCounts()
        let input = AuthProfileSelector.SelectionInput(
            pool: credentialPool,
            cooldownStates: cooldownStates,
            strategy: rotationStrategy,
            excludeIDs: excludeIDs,
            roundRobinCursor: cursor,
            usageCounts: usageCounts
        )
        guard let result = AuthProfileSelector.selectNext(input) else { return nil }
        await rotationState.setRoundRobinCursor(result.nextRoundRobinCursor)
        return result
    }

    private func shouldRotateCredential(for error: Error) async -> Bool {
        let classification = ProviderRuntimeHooks.failoverClassification(
            error: error,
            providerID: binding.providerId
        )
        return ProviderFailoverRecoveryHints.hints(for: classification).shouldRotateCredential
    }

    private func markCooldown(for credential: AuthProfile, error: Error) async {
        let classification = ProviderRuntimeHooks.failoverClassification(
            error: error,
            providerID: binding.providerId
        )
        var effectiveRateLimitCooldown = rateLimitCooldown
        if let retryAfter = TransientErrorClassifier.retryAfterSeconds(error) {
            effectiveRateLimitCooldown = max(rateLimitCooldown, retryAfter)
        }
        await cooldownRegistry.mark(
            key: credential.id,
            classification: classification,
            now: Date(),
            billingCooldown: billingCooldown,
            rateLimitCooldown: effectiveRateLimitCooldown
        )
    }

    private func emitAttempt(
        credential: AuthProfile,
        outcome: ModelCallAttemptOutcome,
        error: Error?
    ) async {
        guard let modelID, let attemptObserver else { return }
        await attemptObserver(
            ModelCallAttemptObservation(
                modelID: modelID,
                callID: ModelInvocationTaskContext.callID,
                kind: .credentialRotation,
                outcome: outcome,
                errorClass: error.map(Self.errorClass),
                errorCode: error.flatMap(Self.errorCode),
                providerID: binding.providerId,
                endpointModelID: binding.endpointModelId,
                authProfileCredentialID: credential.id
            )
        )
    }

    private static func errorClass(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        return TransientErrorClassifier.classify(error) == .transient ? "transient" : "terminal"
    }

    private static func errorCode(_ error: Error) -> String? {
        if let llmError = error as? LLMError {
            switch llmError {
            case .timeout: return "timeout"
            case .rateLimitExceeded: return "rate_limit"
            case .authenticationFailed: return "authentication_failed"
            case .modelNotFound: return "model_not_found"
            case .invalidRequest: return "invalid_request"
            case .networkError: return "network_error"
            case .quotaExceeded: return "quota_exceeded"
            case .unsupportedCapability: return "unsupported_capability"
            default: return "other_llm_error"
            }
        }
        return nil
    }
}
