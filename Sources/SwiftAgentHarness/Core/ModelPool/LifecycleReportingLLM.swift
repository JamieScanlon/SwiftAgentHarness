import Foundation
import SwiftAgentKit

/// Emits lifecycle phases around delegate LLM calls. Intended to sit **inside** ``SchedulingLLM`` so queue phases run first.
struct LifecycleReportingLLM: LLMProtocol {
    private let baseLLM: any LLMProtocol
    private let modelID: UUID
    private let coordinator: any ModelInvocationLifecycleTracking

    init(
        baseLLM: any LLMProtocol,
        modelID: UUID,
        coordinator: any ModelInvocationLifecycleTracking
    ) {
        self.baseLLM = baseLLM
        self.modelID = modelID
        self.coordinator = coordinator
    }

    var currentState: LLMRuntimeState { baseLLM.currentState }

    var stateUpdates: AsyncStream<LLMRuntimeState> { baseLLM.stateUpdates }

    func getModelName() -> String { baseLLM.getModelName() }

    func getCapabilities() -> [LLMCapability] { baseLLM.getCapabilities() }

    func getRequestFeatures() -> ModelRequestFeatures { baseLLM.getRequestFeatures() }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let callID: UUID
        if let scoped = ModelInvocationTaskContext.callID {
            callID = scoped
        } else {
            callID = await coordinator.beginCall(modelID: modelID)
        }
        await coordinator.recordTransition(modelID: modelID, phase: .connecting, callID: callID)
        do {
            let response = try await baseLLM.send(messages, config: config)
            await coordinator.recordResponseMetrics(modelID: modelID, callID: callID, response: response)
            await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
            return response
        } catch is CancellationError {
            await coordinator.recordTransition(modelID: modelID, phase: .cancelled, callID: callID)
            throw CancellationError()
        } catch {
            await coordinator.recordError(modelID: modelID, callID: callID, error: error)
            await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: callID)
            throw error
        }
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let upstream = baseLLM.stream(messages, config: config)
        return AsyncThrowingStream { continuation in
            Task {
                let streamCallID: UUID
                if let scoped = ModelInvocationTaskContext.callID {
                    streamCallID = scoped
                } else {
                    streamCallID = await coordinator.beginCall(modelID: modelID)
                }

                await coordinator.recordTransition(modelID: modelID, phase: .connecting, callID: streamCallID)
                await coordinator.scheduleConnectingThinkingRefresh(modelID: modelID)

                var firstStreamPartial = true
                do {
                    for try await result in upstream {
                        switch result {
                        case .stream(let partial):
                            if firstStreamPartial {
                                firstStreamPartial = false
                                await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: streamCallID)
                            }
                            await coordinator.recordStreamPartial(modelID: modelID, callID: streamCallID, partial: partial)
                            continuation.yield(.stream(partial))
                        case .complete(let final):
                            await coordinator.recordTransition(modelID: modelID, phase: .completing, callID: streamCallID)
                            await coordinator.recordStreamPartial(modelID: modelID, callID: streamCallID, partial: final)
                            await coordinator.recordResponseMetrics(modelID: modelID, callID: streamCallID, response: final)
                            continuation.yield(.complete(final))
                        }
                    }
                    await coordinator.recordTransition(modelID: modelID, phase: .done, callID: streamCallID)
                    continuation.finish()
                } catch is CancellationError {
                    await coordinator.recordTransition(modelID: modelID, phase: .cancelled, callID: streamCallID)
                    continuation.finish(throwing: CancellationError())
                } catch {
                    await coordinator.recordError(modelID: modelID, callID: streamCallID, error: error)
                    await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: streamCallID)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let callID: UUID
        if let scoped = ModelInvocationTaskContext.callID {
            callID = scoped
        } else {
            callID = await coordinator.beginCall(modelID: modelID)
        }
        await coordinator.recordTransition(modelID: modelID, phase: .connecting, callID: callID)
        do {
            let out = try await baseLLM.generateImage(config)
            await coordinator.recordResponseMetrics(
                modelID: modelID,
                callID: callID,
                response: LLMResponse(content: "", toolCalls: [])
            )
            await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
            return out
        } catch is CancellationError {
            await coordinator.recordTransition(modelID: modelID, phase: .cancelled, callID: callID)
            throw CancellationError()
        } catch {
            await coordinator.recordError(modelID: modelID, callID: callID, error: error)
            await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: callID)
            throw error
        }
    }
}
