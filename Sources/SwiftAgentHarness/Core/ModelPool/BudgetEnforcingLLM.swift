import Foundation
import Logging
import SwiftAgentKit

/// Per-call dispatch-boundary gate that authorizes against ``BudgetAccounting`` before
/// invoking the inner LLM and settles after the call terminates (Phase 7 Budget migrate).
///
/// Layering inside the orchestrator stack:
/// `... SchedulingLLM(LifecycleReportingLLM(BudgetEnforcingLLM(RetryingLLM(adapter)))) ...`
///
/// - **Outside** ``RetryingLLM`` so a single authorize/settle pair covers all retries of
///   one logical call (caps are not consumed per retry attempt).
/// - **Inside** ``LifecycleReportingLLM`` so a budget rejection records `.errored` via the
///   lifecycle reporting path (no new lifecycle wiring required).
/// - **Inside** ``SchedulingLLM`` because the factory builds the inner stack only; a
///   rejected call briefly takes scheduler in-flight capacity then releases. Acceptable
///   trade-off at always-allow defaults; revisitable when real accounting lands.
///
/// Uses model-cost metadata for best-effort projected/actual USD inputs. This stays policy-light:
/// accounting implementations still own enforcement decisions.
struct BudgetEnforcingLLM: LLMProtocol {
    let base: any LLMProtocol
    let accounting: any BudgetAccounting
    let policy: BudgetPolicy
    let modelID: UUID
    let conversationID: UUID?
    let ownerAccountID: UUID?
    let modelCost: ModelCostBudget?
    let logger: Logger?

    init(
        base: any LLMProtocol,
        accounting: any BudgetAccounting,
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        ownerAccountID: UUID? = nil,
        modelCost: ModelCostBudget?,
        logger: Logger? = nil
    ) {
        self.base = base
        self.accounting = accounting
        self.policy = policy
        self.modelID = modelID
        self.conversationID = conversationID
        self.ownerAccountID = ownerAccountID
        self.modelCost = modelCost
        self.logger = logger
    }

    var currentState: LLMRuntimeState { base.currentState }

    var stateUpdates: AsyncStream<LLMRuntimeState> { base.stateUpdates }

    func getModelName() -> String { base.getModelName() }

    func getCapabilities() -> [LLMCapability] { base.getCapabilities() }

    func getRequestFeatures() -> ModelRequestFeatures { base.getRequestFeatures() }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let projected = projectedCostUSD(messages: messages, config: config)
        // `ModelQuery.maximumCostPer1MCombinedUSD` can pre-filter candidates, but this
        // dispatch boundary remains the authoritative enforcement gate.
        try await ModelPoolBudgetDispatch.authorize(
            accounting: accounting,
            policy: policy,
            modelID: modelID,
            conversationID: conversationID,
            accountID: ownerAccountID,
            projectedCostUSD: projected
        )
        do {
            let response = try await base.send(messages, config: config)
            await ModelPoolBudgetDispatch.settle(
                accounting: accounting,
                policy: policy,
                modelID: modelID,
                conversationID: conversationID,
                accountID: ownerAccountID,
                actualCostUSD: actualCostUSD(from: response.metadata)
            )
            return response
        } catch is CancellationError {
            // Cancellation releases any pre-authorized reservation.
            await ModelPoolBudgetDispatch.settle(
                accounting: accounting,
                policy: policy,
                modelID: modelID,
                conversationID: conversationID,
                accountID: ownerAccountID,
                actualCostUSD: 0
            )
            throw CancellationError()
        } catch {
            await ModelPoolBudgetDispatch.settle(
                accounting: accounting,
                policy: policy,
                modelID: modelID,
                conversationID: conversationID,
                accountID: ownerAccountID,
                actualCostUSD: nil
            )
            throw error
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let projected = projectedImageCostUSD(config: config)
        try await ModelPoolBudgetDispatch.authorize(
            accounting: accounting,
            policy: policy,
            modelID: modelID,
            conversationID: conversationID,
            accountID: ownerAccountID,
            projectedCostUSD: projected
        )
        do {
            let response = try await base.generateImage(config)
            await ModelPoolBudgetDispatch.settle(
                accounting: accounting,
                policy: policy,
                modelID: modelID,
                conversationID: conversationID,
                accountID: ownerAccountID,
                actualCostUSD: projected
            )
            return response
        } catch is CancellationError {
            await ModelPoolBudgetDispatch.settle(
                accounting: accounting,
                policy: policy,
                modelID: modelID,
                conversationID: conversationID,
                accountID: ownerAccountID,
                actualCostUSD: 0
            )
            throw CancellationError()
        } catch {
            await ModelPoolBudgetDispatch.settle(
                accounting: accounting,
                policy: policy,
                modelID: modelID,
                conversationID: conversationID,
                accountID: ownerAccountID,
                actualCostUSD: nil
            )
            throw error
        }
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await ModelPoolBudgetDispatch.authorize(
                        accounting: accounting,
                        policy: policy,
                        modelID: modelID,
                        conversationID: conversationID,
                        accountID: ownerAccountID,
                        projectedCostUSD: projectedCostUSD(messages: messages, config: config)
                    )
                } catch {
                    // Authorization failed before any partial yielded — propagate without
                    // settling (no authorize success means nothing to settle).
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    var terminalResponse: LLMResponse?
                    for try await result in base.stream(messages, config: config) {
                        if case .complete(let final) = result {
                            terminalResponse = final
                        }
                        continuation.yield(result)
                    }
                    await ModelPoolBudgetDispatch.settle(
                        accounting: accounting,
                        policy: policy,
                        modelID: modelID,
                        conversationID: conversationID,
                        accountID: ownerAccountID,
                        actualCostUSD: actualCostUSD(from: terminalResponse?.metadata)
                    )
                    continuation.finish()
                } catch is CancellationError {
                    // Cancellation releases any pre-authorized reservation.
                    await ModelPoolBudgetDispatch.settle(
                        accounting: accounting,
                        policy: policy,
                        modelID: modelID,
                        conversationID: conversationID,
                        accountID: ownerAccountID,
                        actualCostUSD: 0
                    )
                    continuation.finish(throwing: CancellationError())
                } catch {
                    await ModelPoolBudgetDispatch.settle(
                        accounting: accounting,
                        policy: policy,
                        modelID: modelID,
                        conversationID: conversationID,
                        accountID: ownerAccountID,
                        actualCostUSD: nil
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func projectedCostUSD(messages: [Message], config: LLMRequestConfig) -> Double? {
        guard let cost = modelCost,
              let inputRate = cost.inputPer1MUSD,
              let outputRate = cost.outputPer1MUSD
        else { return nil }
        let estimatedInputTokens = max(1, messages.reduce(0) { $0 + max(1, $1.content.count / 4) })
        let estimatedOutputTokens = max(
            1,
            LLMTokenMetadataBuilder.maxCompletionTokens(from: config) ?? min(1024, config.maxTokens ?? 1024)
        )
        let inputUSD = (Double(estimatedInputTokens) / 1_000_000.0) * inputRate
        let outputUSD = (Double(estimatedOutputTokens) / 1_000_000.0) * outputRate
        return inputUSD + outputUSD
    }

    private func actualCostUSD(from metadata: LLMMetadata?) -> Double? {
        guard let cost = modelCost,
              let inputRate = cost.inputPer1MUSD,
              let outputRate = cost.outputPer1MUSD,
              let metadata
        else { return nil }
        let promptTokens = max(0, metadata.promptTokens ?? 0)
        let completionTokens = max(0, metadata.completionTokens ?? 0)
        let inputUSD = (Double(promptTokens) / 1_000_000.0) * inputRate
        let outputUSD = (Double(completionTokens) / 1_000_000.0) * outputRate
        return inputUSD + outputUSD
    }

    private func projectedImageCostUSD(config: ImageGenerationRequestConfig) -> Double? {
        guard let cost = modelCost, let inputRate = cost.inputPer1MUSD else { return nil }
        let estimatedPromptTokens = max(1, config.prompt.count / 4)
        return (Double(estimatedPromptTokens) / 1_000_000.0) * inputRate
    }
}
