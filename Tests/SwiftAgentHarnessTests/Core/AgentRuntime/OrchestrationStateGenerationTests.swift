import Foundation
import SwiftAgentHarness
import Testing

@Suite("ConversationOrchestrationState generation & coalescing")
struct OrchestrationStateGenerationTests {
    @Test("Codable round-trips orchestrationGeneration")
    func codableRoundTrip() throws {
        let original = ConversationOrchestrationState(
            agenticPhase: .executingTools,
            orchestrationGeneration: 7
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationOrchestrationState.self, from: data)
        #expect(decoded.orchestrationGeneration == 7)
        #expect(decoded.agenticPhase == .executingTools)
    }

    @Test("Codable round-trips optional harness supplement")
    func codableHarnessSupplement() throws {
        let sup = HarnessOrchestrationSupplement(
            milestone: "modelCallStarted",
            terminationCategory: "naturalStop",
            terminationDetail: nil
        )
        let original = ConversationOrchestrationState(
            agenticPhase: .llmCall,
            harness: sup
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationOrchestrationState.self, from: data)
        #expect(decoded.harness?.milestone == "modelCallStarted")
        #expect(decoded.harness?.terminationCategory == "naturalStop")
    }

    @Test("Decode legacy JSON without orchestrationGeneration yields nil")
    func decodeLegacyMissingGeneration() throws {
        let json = """
        {"llmRuntimePhase":"idleReady","agenticPhase":"idle","planHasBlockedTasks":false,"planAllTasksComplete":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConversationOrchestrationState.self, from: json)
        #expect(decoded.orchestrationGeneration == nil)
    }

    @Test("shouldApply: first snapshot always applies")
    func shouldApplyFirst() {
        let s = ConversationOrchestrationState(agenticPhase: .idle, orchestrationGeneration: 1)
        #expect(ConversationOrchestrationState.shouldApplyOrchestrationUpdate(incoming: s, replacing: nil))
    }

    @Test("shouldApply: newer generation replaces")
    func shouldApplyNewer() {
        let cur = ConversationOrchestrationState(agenticPhase: .llmCall, orchestrationGeneration: 2)
        let inc = ConversationOrchestrationState(agenticPhase: .completed, orchestrationGeneration: 3)
        #expect(ConversationOrchestrationState.shouldApplyOrchestrationUpdate(incoming: inc, replacing: cur))
    }

    @Test("shouldApply: older generation rejected")
    func shouldRejectOlder() {
        let cur = ConversationOrchestrationState(agenticPhase: .completed, orchestrationGeneration: 5)
        let inc = ConversationOrchestrationState(agenticPhase: .llmCall, orchestrationGeneration: 4)
        #expect(!ConversationOrchestrationState.shouldApplyOrchestrationUpdate(incoming: inc, replacing: cur))
    }

    @Test("shouldApply: same generation applies (idempotent retry)")
    func shouldApplySameGeneration() {
        let cur = ConversationOrchestrationState(agenticPhase: .idle, orchestrationGeneration: 9)
        let inc = ConversationOrchestrationState(agenticPhase: .idle, orchestrationGeneration: 9)
        #expect(ConversationOrchestrationState.shouldApplyOrchestrationUpdate(incoming: inc, replacing: cur))
    }

    @Test("shouldApply: nil generation on incoming always applies (auxiliary / legacy)")
    func shouldApplyWhenIncomingOmitsGeneration() {
        let cur = ConversationOrchestrationState(agenticPhase: .idle, orchestrationGeneration: 100)
        let inc = ConversationOrchestrationState(agenticPhase: .idle, orchestrationGeneration: nil)
        #expect(ConversationOrchestrationState.shouldApplyOrchestrationUpdate(incoming: inc, replacing: cur))
    }

    @Test("shouldApply: rejects stale mid-turn snapshot without generation")
    func shouldRejectRegressiveMidTurnWithoutGeneration() {
        let runID = UUID()
        let cur = ConversationOrchestrationState(
            llmRuntimePhase: .generatingReasoning,
            agenticPhase: .betweenIterations,
            llmRequestPhase: .generating,
            orchestrationGeneration: 9,
            currentRunID: runID
        )
        let inc = ConversationOrchestrationState(
            llmRuntimePhase: .idleCompleted,
            agenticPhase: .betweenIterations,
            llmRequestPhase: .completed,
            currentRunID: runID
        )
        #expect(!ConversationOrchestrationState.shouldApplyOrchestrationUpdate(incoming: inc, replacing: cur))
    }

    @Test("shouldApply: rejects regressive snapshot at same generation")
    func shouldRejectRegressiveAtSameGeneration() {
        let runID = UUID()
        let cur = ConversationOrchestrationState(
            llmRuntimePhase: .generatingReasoning,
            agenticPhase: .betweenIterations,
            llmRequestPhase: .generating,
            orchestrationGeneration: 9,
            currentRunID: runID
        )
        let inc = ConversationOrchestrationState(
            llmRuntimePhase: .idleCompleted,
            agenticPhase: .betweenIterations,
            llmRequestPhase: .completed,
            orchestrationGeneration: 9,
            currentRunID: runID
        )
        #expect(!ConversationOrchestrationState.shouldApplyOrchestrationUpdate(incoming: inc, replacing: cur))
    }

    @Test("shouldApply: nil generation on current always applies")
    func shouldApplyWhenCurrentOmitsGeneration() {
        let cur = ConversationOrchestrationState(agenticPhase: .idle, orchestrationGeneration: nil)
        let inc = ConversationOrchestrationState(agenticPhase: .completed, orchestrationGeneration: 1)
        #expect(ConversationOrchestrationState.shouldApplyOrchestrationUpdate(incoming: inc, replacing: cur))
    }

    @Test("hasSameWireOrchestrationPhases ignores generation and token counters")
    func wirePhaseEqualityIgnoresGeneration() {
        let a = ConversationOrchestrationState(
            agenticPhase: .idle,
            llmRequestPhase: .idle,
            remainingContextTokens: 100,
            orchestrationGeneration: 801
        )
        let b = ConversationOrchestrationState(
            agenticPhase: .idle,
            llmRequestPhase: .idle,
            remainingContextTokens: 50,
            orchestrationGeneration: 922
        )
        #expect(a.hasSameWireOrchestrationPhases(as: b))
        let c = ConversationOrchestrationState(agenticPhase: .llmCall, orchestrationGeneration: 923)
        #expect(!a.hasSameWireOrchestrationPhases(as: c))
    }

    @Test("orchestrationGeneration fromJSONValue parses Int and NSNumber")
    func jsonValueParsing() {
        #expect(ConversationOrchestrationState.orchestrationGeneration(fromJSONValue: 42) == 42)
        #expect(ConversationOrchestrationState.orchestrationGeneration(fromJSONValue: Int64(99)) == 99)
        #expect(ConversationOrchestrationState.orchestrationGeneration(fromJSONValue: nil) == nil)
        let num = NSNumber(value: 1001)
        #expect(ConversationOrchestrationState.orchestrationGeneration(fromJSONValue: num) == 1001)
    }
}
