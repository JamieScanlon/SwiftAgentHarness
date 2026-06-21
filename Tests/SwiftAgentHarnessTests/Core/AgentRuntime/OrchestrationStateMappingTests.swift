import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("OrchestrationStateMapping deterministic picks")
struct OrchestrationStateMappingTests {
    @Test("Agentic loop ids sort deterministically (orchestratorSession before a2a lexicographically by key)")
    func stableAgenticKeysSort() {
        let u1 = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let u2 = UUID(uuidString: "FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let a: AgenticLoopID = .orchestratorSession(u1)
        let b: AgenticLoopID = .orchestratorSession(u2)
        let ka = OrchestrationStateMapping.stableAgenticLoopSortKey(a)
        let kb = OrchestrationStateMapping.stableAgenticLoopSortKey(b)
        #expect(ka < kb)
    }

    @Test("pickAgenticPhase prefers in-progress loop over completed when two orchestrator sessions exist")
    func pickPrefersInProgressAgentic() {
        let uDone = UUID()
        let uActive = UUID()
        let states: [AgenticLoopID: AgenticLoopState] = [
            .orchestratorSession(uDone): .completed,
            .orchestratorSession(uActive): .executingTools
        ]
        let phase = OrchestrationStateMapping.pickAgenticPhase(from: states, fallback: .idle)
        #expect(phase == .executingTools)
    }

    @Test("pickRequestPhase prefers in-flight request when two ids exist")
    func pickPrefersInProgressRequest() {
        let r1 = LLMRequestID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let r2 = LLMRequestID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let states: [LLMRequestID: LLMRequestState] = [
            r1: .completed,
            r2: .streaming
        ]
        let phase = OrchestrationStateMapping.pickRequestPhase(from: states, fallback: nil)
        #expect(phase == .streaming)
    }

    @Test("pickRequestPhase prefers most advanced in-progress phase over stale queued")
    func pickPrefersStreamingOverQueuedWhenBothInProgress() {
        let queuedID = LLMRequestID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let streamingID = LLMRequestID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let states: [LLMRequestID: LLMRequestState] = [
            queuedID: .queued,
            streamingID: .streaming
        ]
        let phase = OrchestrationStateMapping.pickRequestPhase(from: states, fallback: .idle)
        #expect(phase == .streaming)
    }

    @Test("pickAgenticPhase prefers advanced in-progress phase over stale started")
    func pickPrefersAdvancedAgenticOverStarted() {
        let startedID = AgenticLoopID.orchestratorSession(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let llmCallID = AgenticLoopID.orchestratorSession(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let states: [AgenticLoopID: AgenticLoopState] = [
            startedID: .started,
            llmCallID: .llmCall(iteration: 1)
        ]
        let phase = OrchestrationStateMapping.pickAgenticPhase(from: states, fallback: .idle)
        #expect(phase == .llmCall)
    }

    @Test("Harness supplement: milestone for in-flight agentic LLM call")
    func harnessMilestoneModelCallStarted() {
        let u = UUID()
        let h = HarnessOrchestrationSupplementBuilder.build(
            agenticLoopStates: [.orchestratorSession(u): .llmCall(iteration: 0)],
            perRequestStates: [:]
        )
        #expect(h?.milestone == "modelCallStarted")
        #expect(h?.terminationCategory == nil)
    }

    @Test("Harness supplement: terminal natural stop")
    func harnessTerminationNaturalStop() {
        let u = UUID()
        let h = HarnessOrchestrationSupplementBuilder.build(
            agenticLoopStates: [.orchestratorSession(u): .completed],
            perRequestStates: [:]
        )
        #expect(h?.terminationCategory == "naturalStop")
    }

    @Test("Harness supplement: cancelled request beats completed agentic")
    func harnessCancellationPriority() {
        let u = UUID()
        let r = LLMRequestID(UUID())
        let h = HarnessOrchestrationSupplementBuilder.build(
            agenticLoopStates: [.orchestratorSession(u): .completed],
            perRequestStates: [r: .cancelled]
        )
        #expect(h?.terminationCategory == "externalCancellation")
    }
}
