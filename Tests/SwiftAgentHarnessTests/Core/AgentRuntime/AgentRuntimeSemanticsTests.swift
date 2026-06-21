import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Agent Runtime — harness semantics")
struct AgentRuntimeSemanticsTests {
    private struct StubToolError: AgentRuntimeToolError {}

    @Test("maxIterationsReached classifies as bounded stop")
    func maxIterationsBounded() {
        let c = HarnessTurnTermination.category(forTerminalAgenticState: .maxIterationsReached)
        #expect(c == .boundedStop(.maxAgentIterations))
    }

    @Test("completed classifies as natural stop")
    func completedNatural() {
        let c = HarnessTurnTermination.category(forTerminalAgenticState: .completed)
        #expect(c == .naturalStop)
    }

    @Test("request cancelled classifies as external cancellation")
    func requestCancelled() {
        let c = HarnessTurnTermination.category(forTerminalRequestState: .cancelled)
        #expect(c == .externalCancellation)
    }

    @Test("progressMilestone is nil for terminal agentic states")
    func progressNilWhenTerminal() {
        #expect(AgentRuntimeLogicalEvent.progressMilestone(for: .completed) == nil)
        #expect(AgentRuntimeLogicalEvent.progressMilestone(for: .maxIterationsReached) == nil)
    }

    @Test("progressMilestone for in-progress states")
    func progressWhenInProgress() {
        #expect(AgentRuntimeLogicalEvent.progressMilestone(for: .llmCall(iteration: 0)) == .modelCallStarted)
    }

    @Test("cancellation error maps to cancellation class and fail policy")
    func cancellationErrorPolicy() {
        let outcome = AgentRuntimeErrorPolicy.outcome(for: CancellationError())
        #expect(outcome.errorClass == .cancellation)
        #expect(outcome.handling == .failTurn)
    }

    @Test("runtime error maps to runtime class and fail policy")
    func runtimeErrorPolicy() {
        let runtimeError = NSError(domain: "AgentRuntimeSemanticsTests", code: 1)
        let outcome = AgentRuntimeErrorPolicy.outcome(for: runtimeError)
        #expect(outcome.errorClass == .runtime)
        #expect(outcome.handling == .failTurn)
    }

    @Test("tool error policy is continue-loop")
    func toolErrorPolicy() {
        let outcome = AgentRuntimeErrorPolicy.outcome(for: .tool)
        #expect(outcome.errorClass == .tool)
        #expect(outcome.handling == .continueLoop)
    }

    @Test("model/pool errors classify distinctly")
    func modelPoolClassification() {
        let llm = AgentRuntimeErrorPolicy.classify(LLMError.invalidRequest("x"))
        let pool = AgentRuntimeErrorPolicy.classify(
            ModelPoolError.unavailable(reference: .slug("missing-model"))
        )
        #expect(llm == .modelOrPool)
        #expect(pool == .modelOrPool)
    }

    @Test("tool marker errors classify as tool and continue")
    func toolMarkerClassification() {
        let classified = AgentRuntimeErrorPolicy.classify(StubToolError())
        let outcome = AgentRuntimeErrorPolicy.outcome(for: StubToolError())
        #expect(classified == .tool)
        #expect(outcome.handling == .continueLoop)
    }

    @Test("coordinator failure mapping continues for tool errors")
    func coordinatorFailureMappingForToolErrors() {
        let result = AgentRuntimeCoordinator.failureResult(for: StubToolError())
        #expect(result.terminalState == .completed)
        #expect(result.terminalReason?.detail == "tool_error_continued")
    }

    @Test("coordinator failure mapping fails for model/pool errors")
    func coordinatorFailureMappingForModelPoolErrors() {
        let result = AgentRuntimeCoordinator.failureResult(for: LLMError.invalidRequest("nope"))
        #expect(result.terminalState == .failed)
        #expect(result.errorPolicy?.errorClass == .modelOrPool)
    }

    @Test("cancelled run result carries external cancellation reason")
    func cancelledRunResultReason() {
        let result = AgentRuntimeRunResult.cancelled()
        #expect(result.terminalState == .cancelled)
        #expect(result.terminalReason?.category == .externalCancellation)
    }

    @Test("completed run result preserves bounded reason")
    func completedRunResultReason() {
        let reason = ConversationRunTerminalReason(
            category: .boundedStop,
            boundedReason: .maxContinuationRounds
        )
        let result = AgentRuntimeRunResult.completed(reason: reason)
        #expect(result.terminalState == .completed)
        #expect(result.terminalReason?.boundedReason == .maxContinuationRounds)
    }

    @Test("terminal lifecycle event name maps cancellation and bounded stops")
    func terminalLifecycleEventNames() {
        let cancelled = ConversationRunTerminalReason(category: .externalCancellation, detail: "user_stop_requested")
        let bounded = ConversationRunTerminalReason(category: .boundedStop, boundedReason: .maxContinuationRounds)
        let natural = ConversationRunTerminalReason(category: .naturalStop)
        #expect(AgentRuntimeLifecycleEmitter.terminalEventName(for: cancelled) == .turnCancelled)
        #expect(AgentRuntimeLifecycleEmitter.terminalEventName(for: bounded) == .turnBounded)
        #expect(AgentRuntimeLifecycleEmitter.terminalEventName(for: natural) == .turnCompleted)
    }
}
