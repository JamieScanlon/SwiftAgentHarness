import Foundation
import Synchronization
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import Testing
@testable import SwiftAgentHarness

/// The turn loop actually producing the usage-bearing event.
///
/// `MainLoopCompletionUsageTests` covers the rollup and the pricing, but every one of its cases
/// hand-builds the audit row — so all of them would pass with `TurnLoop` reverted wholesale. That
/// blind spot is not hypothetical: the first version of this change built the usage payload
/// unconditionally, which defeated the audit path's `usage != nil` gate and would have persisted an
/// empty, never-pruned derived row for every model call. Nothing in that file could see it. This
/// drives the real loop.
@Suite("TurnLoop completion usage")
struct TurnLoopCompletionUsageTests {
    private static let rates = ModelCostBudget(inputPer1MUSD: 3, outputPer1MUSD: 15)

    private func makeModel(cost: ModelCostBudget?) -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "usage-conformance",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            requestFeatures: ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text],
                parallelToolCalls: .uncapped,
                reasoningEfforts: [],
                toolChoiceModes: [.auto, .none, .required, .specific]
            ),
            cost: cost
        )
    }

    /// Runs one turn whose single completion reports `metadata`, and returns the payloads emitted.
    private func runTurn(
        cost: ModelCostBudget?,
        metadata: LLMMetadata?,
        settledCostUSD: Double? = nil
    ) async throws -> (payloads: [RuntimeLifecycleEventPayload], runID: UUID) {
        let conversationID = UUID()
        let runID = UUID()
        let state = TurnLoopConversationState(
            conversation: ModelConversation(
                id: conversationID,
                model: makeModel(cost: cost),
                messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
                turns: [],
                interactionMode: .chat
            )
        )
        let sink = ModelCompletionSettlementSink()
        if let settledCostUSD {
            sink.record(conversationID: conversationID, costUSD: settledCostUSD)
        }
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.stream(LLMResponse(content: "done", toolCalls: [])))
                    continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [], metadata: metadata)))
                    continuation.finish()
                }
            },
            settlementSink: sink
        )
        let captured = Mutex<[RuntimeLifecycleEventPayload]>([])
        _ = try await TurnLoop(ports: ports).run(
            conversationID: conversationID,
            runID: runID,
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: SwiftAgentKitOrchestrator(
                llm: StubTurnLoopLLM(),
                config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
            ),
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, payload in
                captured.withLock { $0.append(payload) }
            }
        )
        return (captured.withLock { $0 }, runID)
    }

    private func completion(_ payloads: [RuntimeLifecycleEventPayload]) throws -> RuntimeLifecycleEventPayload {
        try #require(payloads.first { $0.name == .modelCallCompleted })
    }

    /// The claim the whole change rests on: a turn that never delegates still reports what it cost.
    @Test("a completed turn reports its own tokens and a priced cost")
    func turnReportsPricedUsage() async throws {
        let (payloads, runID) = try await runTurn(
            cost: Self.rates,
            metadata: LLMMetadata(promptTokens: 2_000_000, completionTokens: 100_000, totalTokens: 2_100_000)
        )
        let event = try completion(payloads)
        let usage = try #require(event.usage)
        #expect(usage.promptTokens == 2_000_000)
        #expect(usage.completionTokens == 100_000)
        #expect(usage.totalTokens == 2_100_000)
        // 2M input at $3/1M + 100k output at $15/1M.
        #expect(abs((usage.costUSD ?? 0) - 7.5) < 0.000_001)
        // The correlation fields the audit row deduplicates on.
        #expect(event.toolName == RuntimeLifecycleModelCompletionAudit.toolName)
        #expect(event.toolCallID == RuntimeLifecycleModelCompletionAudit.correlationID(runID: runID, iteration: 1))
    }

    /// The point of the sink. `BudgetEnforcingLLM` is built per *dispatched* model, and
    /// mode-profile routing or ranked fallback can substitute one the conversation never named — so
    /// pricing from `conv.model.cost` billed a routed call at the wrong rates. When the gate has
    /// settled a figure, that figure wins.
    @Test("the settled cost wins over the conversation model's rates")
    func settledCostOverridesConversationRates() async throws {
        let (payloads, _) = try await runTurn(
            cost: Self.rates,
            metadata: LLMMetadata(promptTokens: 2_000_000, completionTokens: 100_000, totalTokens: 2_100_000),
            settledCostUSD: 0.25
        )
        let usage = try #require(try completion(payloads).usage)
        // The conversation's rates would have produced 7.5.
        #expect(abs((usage.costUSD ?? 0) - 0.25) < 0.000_001)
        #expect(usage.promptTokens == 2_000_000)
    }

    /// The branch that was broken. A sink is wired but the gate settled nothing — a host whose
    /// factory is not a `StandardModelLLMFactory`, or a completion the gate could not price. The
    /// catalog fallback has to still run; optional-chaining the consume made it unreachable.
    @Test("an unsettled completion still falls back to the conversation model's rates")
    func unsettledCompletionFallsBackToCatalogRates() async throws {
        let (payloads, _) = try await runTurn(
            cost: Self.rates,
            metadata: LLMMetadata(promptTokens: 2_000_000, completionTokens: 100_000, totalTokens: 2_100_000),
            settledCostUSD: nil
        )
        let usage = try #require(try completion(payloads).usage)
        #expect(abs((usage.costUSD ?? 0) - 7.5) < 0.000_001)
    }

    /// A model the conversation cannot price is exactly the case that read `$0` before — the gate
    /// still knows what it cost, because it holds the dispatched model's rates.
    @Test("a settled cost rescues a conversation model with no rates")
    func settledCostRescuesUnpricedConversationModel() async throws {
        let (payloads, _) = try await runTurn(
            cost: nil,
            metadata: LLMMetadata(promptTokens: 10, completionTokens: 5, totalTokens: 15),
            settledCostUSD: 0.02
        )
        #expect(try #require(try completion(payloads).usage).costUSD == 0.02)
    }

    /// Tokens are real even when the model carries no rates. `costUSD` stays nil so the rollup can
    /// tell "unpriced" from "free" — a ledger that reads a missing price as `$0` never binds.
    @Test("an unpriced model still reports its tokens")
    func unpricedModelReportsTokens() async throws {
        let (payloads, _) = try await runTurn(
            cost: nil,
            metadata: LLMMetadata(promptTokens: 10, completionTokens: 5, totalTokens: 15)
        )
        let usage = try #require(try completion(payloads).usage)
        #expect(usage.totalTokens == 15)
        #expect(usage.costUSD == nil)
    }

    /// The regression that motivated this file. A provider that reports nothing must produce a
    /// usage-less event, so the audit path skips it — `tool_audit_lifecycle_event` is
    /// `retentionEligible: false`, so an empty row per model call is re-read on every projection for
    /// the life of the conversation.
    @Test("a completion with no provider metadata carries no usage and no correlation fields")
    func unmeteredCompletionCarriesNothing() async throws {
        let (payloads, _) = try await runTurn(cost: Self.rates, metadata: nil)
        let event = try completion(payloads)
        #expect(event.usage == nil)
        #expect(event.toolName == nil)
        #expect(event.toolCallID == nil)
    }

    /// Zero-token metadata is no signal, not a zero-dollar charge.
    @Test("a zero-token completion is treated as unmetered")
    func zeroTokenCompletionIsUnmetered() async throws {
        let (payloads, _) = try await runTurn(
            cost: Self.rates,
            metadata: LLMMetadata(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        )
        #expect(try completion(payloads).usage == nil)
    }

    /// A provider reporting a negative count must not reach the wire — `PublishingContractValidator`
    /// rejects it, and the emitter publishes this payload straight to the conversation topic.
    @Test("negative provider counts are clamped before publication")
    func negativeCountsAreClamped() async throws {
        let (payloads, _) = try await runTurn(
            cost: Self.rates,
            metadata: LLMMetadata(promptTokens: -5, completionTokens: 1_000_000, totalTokens: -5)
        )
        let usage = try #require(try completion(payloads).usage)
        // Pinned, not just "non-negative" — a dropped field would satisfy `>= 0` too. Note the
        // clamped total no longer equals prompt + completion; the rollup re-derives it downstream.
        #expect(usage.promptTokens == 0)
        #expect(usage.totalTokens == 0)
        #expect(usage.completionTokens == 1_000_000)
    }
}
