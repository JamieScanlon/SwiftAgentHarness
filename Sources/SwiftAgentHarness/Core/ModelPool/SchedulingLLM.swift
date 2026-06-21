import Foundation
import SwiftAgentKit

/// Acquires pool scheduler capacity before delegating to the inner LLM.
/// Records ``ModelInvocationPhase/queued`` before waiting and ``ModelInvocationPhase/dispatching`` after a slot is acquired.
struct SchedulingLLM: LLMProtocol {
    private let baseLLM: any LLMProtocol
    private let scheduler: any ModelCallScheduling
    private let modelID: UUID
    /// When set, lifecycle phases for this call are also fanned to ``conversation/{id}/events`` and
    /// ``conversation/{id}/state`` via the coordinator's conversation publication sink.
    private let conversationID: UUID?
    /// Priority forwarded to ``ModelCallScheduling/acquire(for:priority:)``. Defaults to
    /// ``ModelRequestPriority/foreground`` so existing call sites preserve current behavior; background
    /// callers (compaction, summarization) can opt in by passing `.background`.
    private let priority: ModelRequestPriority
    /// Optional stable scheduler credential key (for per-credential caps/token buckets).
    private let credentialKey: String?
    private let coordinator: (any ModelInvocationLifecycleTracking)?

    init(
        baseLLM: any LLMProtocol,
        scheduler: any ModelCallScheduling,
        modelID: UUID,
        conversationID: UUID? = nil,
        priority: ModelRequestPriority = .foreground,
        credentialKey: String? = nil,
        coordinator: (any ModelInvocationLifecycleTracking)? = nil
    ) {
        self.baseLLM = baseLLM
        self.scheduler = scheduler
        self.modelID = modelID
        self.conversationID = conversationID
        self.priority = priority
        self.credentialKey = credentialKey
        self.coordinator = coordinator
    }

    var currentState: LLMRuntimeState { baseLLM.currentState }

    var stateUpdates: AsyncStream<LLMRuntimeState> { baseLLM.stateUpdates }

    func getModelName() -> String { baseLLM.getModelName() }

    func getCapabilities() -> [LLMCapability] { baseLLM.getCapabilities() }

    func getRequestFeatures() -> ModelRequestFeatures { baseLLM.getRequestFeatures() }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let parentLogicalRequestID = ModelInvocationTaskContext.logicalRequestID
        let callID = await coordinator?.beginCall(
            modelID: modelID,
            conversationID: conversationID,
            logicalRequestID: parentLogicalRequestID
        ) ?? UUID()
        await coordinator?.recordTransition(modelID: modelID, phase: .queued, callID: callID)
        let acquisition = await scheduler.acquire(
            reservation: makeReservation(
                messages: messages,
                priority: priority,
                estimatedTotalTokens: Self.estimateTotalTokens(messages: messages)
            )
        )
        await coordinator?.recordTransition(modelID: modelID, phase: .dispatching, callID: callID)
        do {
            let response = try await ModelInvocationTaskContext.$logicalRequestID.withValue(parentLogicalRequestID ?? callID) {
                try await ModelInvocationTaskContext.$callID.withValue(callID) {
                    try await baseLLM.send(messages, config: config)
                }
            }
            await scheduler.release(acquisition: acquisition)
            await coordinator?.endCall(modelID: modelID, callID: callID)
            return response
        } catch {
            await scheduler.release(acquisition: acquisition)
            await coordinator?.endCall(modelID: modelID, callID: callID)
            throw error
        }
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let parentLogicalRequestID = ModelInvocationTaskContext.logicalRequestID
                let callID = await coordinator?.beginCall(
                    modelID: modelID,
                    conversationID: conversationID,
                    logicalRequestID: parentLogicalRequestID
                ) ?? UUID()
                await coordinator?.recordTransition(modelID: modelID, phase: .queued, callID: callID)
                let acquisition = await scheduler.acquire(
                    reservation: makeReservation(
                        messages: messages,
                        priority: priority,
                        estimatedTotalTokens: Self.estimateTotalTokens(messages: messages)
                    )
                )
                await coordinator?.recordTransition(modelID: modelID, phase: .dispatching, callID: callID)
                let upstream = ModelInvocationTaskContext.$logicalRequestID.withValue(parentLogicalRequestID ?? callID) {
                    ModelInvocationTaskContext.$callID.withValue(callID) {
                        baseLLM.stream(messages, config: config)
                    }
                }
                do {
                    for try await result in upstream {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await scheduler.release(acquisition: acquisition)
                await coordinator?.endCall(modelID: modelID, callID: callID)
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let parentLogicalRequestID = ModelInvocationTaskContext.logicalRequestID
        let callID = await coordinator?.beginCall(
            modelID: modelID,
            conversationID: conversationID,
            logicalRequestID: parentLogicalRequestID
        ) ?? UUID()
        await coordinator?.recordTransition(modelID: modelID, phase: .queued, callID: callID)
        let acquisition = await scheduler.acquire(
            reservation: makeReservation(
                messages: [],
                priority: priority,
                estimatedTotalTokens: 1
            )
        )
        await coordinator?.recordTransition(modelID: modelID, phase: .dispatching, callID: callID)
        do {
            let response = try await ModelInvocationTaskContext.$logicalRequestID.withValue(parentLogicalRequestID ?? callID) {
                try await ModelInvocationTaskContext.$callID.withValue(callID) {
                    try await baseLLM.generateImage(config)
                }
            }
            await scheduler.release(acquisition: acquisition)
            await coordinator?.endCall(modelID: modelID, callID: callID)
            return response
        } catch {
            await scheduler.release(acquisition: acquisition)
            await coordinator?.endCall(modelID: modelID, callID: callID)
            throw error
        }
    }

    private func makeReservation(
        messages: [Message],
        priority: ModelRequestPriority,
        estimatedTotalTokens: Int?
    ) -> ModelCallReservation {
        ModelCallReservation(
            modelID: modelID,
            priority: priority,
            conversationID: conversationID,
            credentialKey: credentialKey,
            estimatedTotalTokens: estimatedTotalTokens
        )
    }

    private static func estimateTotalTokens(messages: [Message]) -> Int {
        let totalCharacters = messages.reduce(0) { partialResult, message in
            partialResult + message.content.count
        }
        return max(1, Int(ceil(Double(totalCharacters) / 4.0)))
    }
}
