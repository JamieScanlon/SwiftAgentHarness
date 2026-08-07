import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

/// Main-loop spend reaching the per-run cost rollup.
///
/// Before this, `authoritativeUsageRollupsByRun` only ever saw usage from the sub-agent completion
/// path — the turn loop emitted `.modelCallCompleted` with none attached — so a conversation that
/// never delegated rolled up to `$0` however much it had cost. That is what left the trigger
/// surface's spend ceilings measuring almost nothing.
@Suite("Main-loop completion usage")
struct MainLoopCompletionUsageTests {
    private func auditRow(
        name: RuntimeLifecycleEventName,
        runID: UUID,
        iteration: Int,
        toolName: String,
        toolCallID: String?,
        completionAnnounceID: UUID? = nil,
        usage: DelegateCompletionUsagePayload?
    ) -> ToolAuditLifecycleEventPayload {
        ToolAuditLifecycleEventPayload(
            name: name,
            runID: runID,
            iteration: iteration,
            modelID: nil,
            toolName: toolName,
            delegateHandleID: nil,
            toolCallID: toolCallID,
            completionAnnounceID: completionAnnounceID,
            usage: usage,
            approvalState: nil,
            policyReason: nil,
            approvalSource: nil,
            approvalReason: nil,
            argumentDigest: nil,
            argumentByteCount: nil,
            argumentRedaction: nil,
            resultDigest: nil,
            resultByteCount: nil,
            resultRedaction: nil,
            resultTruncated: nil,
            executionEnvironmentKind: nil,
            executionEnvironmentAdapterID: nil,
            executionIsolationLevel: nil,
            source: "test",
            createdAt: Date()
        )
    }

    private func events(_ payloads: [ToolAuditLifecycleEventPayload]) -> [CachedConversationEvent] {
        payloads.enumerated().map { index, payload in
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: index + 1,
                kind: ConversationEventKind.toolAuditLifecycleEvent.rawValue,
                payloadJSON: ConversationEventCodec.encode(payload)
            )
        }
    }

    private func modelRow(
        runID: UUID,
        iteration: Int,
        usage: DelegateCompletionUsagePayload?
    ) -> ToolAuditLifecycleEventPayload {
        auditRow(
            name: .modelCallCompleted,
            runID: runID,
            iteration: iteration,
            toolName: RuntimeLifecycleModelCompletionAudit.toolName,
            toolCallID: RuntimeLifecycleModelCompletionAudit.correlationID(runID: runID, iteration: iteration),
            usage: usage
        )
    }

    // MARK: - The rollup

    @Test("a main-loop completion contributes to the run's rollup")
    func modelCompletionCounts() throws {
        let runID = UUID()
        let rollups = TranscriptRunDerivation.authoritativeUsageRollupsByRun(
            events: events([
                modelRow(
                    runID: runID,
                    iteration: 1,
                    usage: DelegateCompletionUsagePayload(promptTokens: 100, completionTokens: 20, totalTokens: 120, costUSD: 0.004)
                )
            ])
        )
        let row = try #require(rollups[runID])
        #expect(row.tokens?.promptTokens == 100)
        #expect(row.tokens?.totalTokens == 120)
        #expect(row.cost?.usd == 0.004)
    }

    /// Distinct iterations are distinct completions and must sum — the previous coverage only ever
    /// asserted that a duplicate pair collapsed to one.
    @Test("successive iterations accumulate")
    func iterationsAccumulate() throws {
        let runID = UUID()
        let rollups = TranscriptRunDerivation.authoritativeUsageRollupsByRun(
            events: events((1 ... 3).map { iteration in
                modelRow(
                    runID: runID,
                    iteration: iteration,
                    usage: DelegateCompletionUsagePayload(promptTokens: 10, completionTokens: 5, totalTokens: 15, costUSD: 0.001)
                )
            })
        )
        let row = try #require(rollups[runID])
        #expect(row.tokens?.promptTokens == 30)
        #expect(row.tokens?.totalTokens == 45)
        #expect(abs((row.cost?.usd ?? 0) - 0.003) < 0.000_001)
    }

    /// The reason the emitter synthesizes a `toolCallID` at all. The rollup's last-resort dedupe key
    /// is the persisted row's own event id, which is unique per row and therefore deduplicates
    /// nothing — a replayed or re-published completion would silently double the run's cost.
    @Test("the same completion published twice is counted once")
    func republishedCompletionIsIdempotent() throws {
        let runID = UUID()
        let usage = DelegateCompletionUsagePayload(promptTokens: 40, completionTokens: 10, totalTokens: 50, costUSD: 0.01)
        let rollups = TranscriptRunDerivation.authoritativeUsageRollupsByRun(
            events: events([
                modelRow(runID: runID, iteration: 2, usage: usage),
                modelRow(runID: runID, iteration: 2, usage: usage),
            ])
        )
        let row = try #require(rollups[runID])
        #expect(row.tokens?.promptTokens == 40)
        #expect(row.cost?.usd == 0.01)
    }

    /// The parent's own tokens and a sub-agent's reported cost are different spend, so they add.
    @Test("main-loop and delegate usage sum within one run")
    func mainLoopAndDelegateSum() throws {
        let runID = UUID()
        let rollups = TranscriptRunDerivation.authoritativeUsageRollupsByRun(
            events: events([
                modelRow(
                    runID: runID,
                    iteration: 1,
                    usage: DelegateCompletionUsagePayload(promptTokens: 10, completionTokens: 5, totalTokens: 15, costUSD: 0.002)
                ),
                auditRow(
                    name: .toolCompletionAnnounced,
                    runID: runID,
                    iteration: 1,
                    toolName: "delegate",
                    toolCallID: "tc_1",
                    completionAnnounceID: UUID(),
                    usage: DelegateCompletionUsagePayload(promptTokens: 90, completionTokens: 45, totalTokens: 135, costUSD: 0.05)
                ),
            ])
        )
        let row = try #require(rollups[runID])
        #expect(row.tokens?.totalTokens == 150)
        // Tolerance, not equality: 0.002 + 0.05 is 0.052000000000000005 in binary floating point.
        #expect(abs((row.cost?.usd ?? 0) - 0.052) < 0.000_001)
    }

    /// A model priced by no catalog rate still contributes its tokens. `costRollup` stays nil rather
    /// than reading `$0`, so "unpriced" remains distinguishable from "free".
    @Test("an unpriced completion records tokens without a cost")
    func unpricedCompletionKeepsTokens() throws {
        let runID = UUID()
        let rollups = TranscriptRunDerivation.authoritativeUsageRollupsByRun(
            events: events([
                modelRow(
                    runID: runID,
                    iteration: 1,
                    usage: DelegateCompletionUsagePayload(promptTokens: 10, completionTokens: 5, totalTokens: 15, costUSD: nil)
                )
            ])
        )
        let row = try #require(rollups[runID])
        #expect(row.tokens?.totalTokens == 15)
        #expect(row.cost == nil)
    }

    /// The correlation id has to be stable for the same completion and distinct across iterations
    /// and runs — it is the whole dedupe contract.
    @Test("the correlation id identifies a completion exactly")
    func correlationIDIsStableAndDistinct() {
        let runA = UUID()
        let runB = UUID()
        let first = RuntimeLifecycleModelCompletionAudit.correlationID(runID: runA, iteration: 1)
        #expect(first == RuntimeLifecycleModelCompletionAudit.correlationID(runID: runA, iteration: 1))
        #expect(first != RuntimeLifecycleModelCompletionAudit.correlationID(runID: runA, iteration: 2))
        #expect(first != RuntimeLifecycleModelCompletionAudit.correlationID(runID: runB, iteration: 1))
        #expect(first.hasPrefix("model:"))
        // A run-less emission must not collide with a real run's first iteration.
        #expect(RuntimeLifecycleModelCompletionAudit.correlationID(runID: nil, iteration: 1) != first)
    }

    // MARK: - The emitter

    /// The correlation fields exist to make the audit row deduplicable, so they must appear exactly
    /// when usage does. Nothing else in this file touches the emitter — which is how the first
    /// version shipped a payload that was never `nil`, silently defeating the audit path's
    /// `usage != nil` gate and persisting an empty, never-pruned derived row per model call.
    @Test("a metered completion carries the correlation fields, an unmetered one carries none")
    func emitterStampsCorrelationOnlyWithUsage() async throws {
        let captured = Mutex<[RuntimeLifecycleEventPayload]>([])
        let emitter = AgentRuntimeLifecycleEmitter { _, payload in
            captured.withLock { $0.append(payload) }
        }
        let runID = UUID()
        let conversationID = UUID()

        await emitter.emit(
            .modelCallCompleted(
                iteration: 4,
                modelID: UUID(),
                usage: DelegateCompletionUsagePayload(promptTokens: 7, completionTokens: 2, totalTokens: 9, costUSD: 0.001)
            ),
            conversationID: conversationID,
            runID: runID
        )
        await emitter.emit(
            .modelCallCompleted(iteration: 5, modelID: UUID()),
            conversationID: conversationID,
            runID: runID
        )

        let payloads = captured.withLock { $0 }
        #expect(payloads.count == 2)
        let metered = try #require(payloads.first)
        #expect(metered.usage?.promptTokens == 7)
        #expect(metered.toolName == RuntimeLifecycleModelCompletionAudit.toolName)
        #expect(metered.toolCallID == RuntimeLifecycleModelCompletionAudit.correlationID(runID: runID, iteration: 4))

        let unmetered = try #require(payloads.last)
        #expect(unmetered.usage == nil)
        // Left clean so the audit path skips it and no empty row is persisted.
        #expect(unmetered.toolName == nil)
        #expect(unmetered.toolCallID == nil)
    }

    // MARK: - Pricing

    /// One formula, shared with `BudgetEnforcingLLM` — two copies is how a budget ledger and a run
    /// rollup come to disagree by a few percent with nobody able to say which is right.
    @Test("cost is tokens against the catalog rates")
    func costArithmetic() throws {
        let cost = ModelCostBudget(inputPer1MUSD: 3, outputPer1MUSD: 15)
        let usd = try #require(
            ModelCompletionCostMath.usd(promptTokens: 1_000_000, completionTokens: 100_000, cost: cost)
        )
        #expect(abs(usd - (3 + 1.5)) < 0.000_001)
    }

    /// Missing rates mean unpriced, not free.
    @Test("an unpriced or unusable model yields no cost")
    func unpricedYieldsNil() {
        #expect(ModelCompletionCostMath.usd(promptTokens: 10, completionTokens: 5, cost: nil) == nil)
        #expect(
            ModelCompletionCostMath.usd(
                promptTokens: 10,
                completionTokens: 5,
                cost: ModelCostBudget(inputPer1MUSD: 3)
            ) == nil
        )
        // No tokens is no signal, not a zero-dollar charge.
        #expect(
            ModelCompletionCostMath.usd(
                promptTokens: 0,
                completionTokens: nil,
                cost: ModelCostBudget(inputPer1MUSD: 3, outputPer1MUSD: 15)
            ) == nil
        )
    }

    @Test("negative token counts cannot credit a cost")
    func negativeTokensClamp() throws {
        let usd = try #require(
            ModelCompletionCostMath.usd(
                promptTokens: -1_000_000,
                completionTokens: 1_000_000,
                cost: ModelCostBudget(inputPer1MUSD: 3, outputPer1MUSD: 15)
            )
        )
        #expect(abs(usd - 15) < 0.000_001)
    }
}
