
import Testing
@testable import SwiftAgentHarness

@Suite("OrchestrationSnapshotComposer inference")
struct OrchestrationSnapshotComposerInferenceTests {
    @Test("infers LLM generating while planning tool use")
    func infersLLMGeneratingForQueuedLLMCall() {
        let inferred = OrchestrationSnapshotComposer.inferredLLMRuntimePhase(
            observed: .idleReady,
            requestPhase: .queued,
            agenticPhase: .llmCall
        )
        #expect(inferred == .generatingResponding)
    }

    @Test("does not force LLM generating for plain queued request")
    func keepsIdleForPlainQueuedRequest() {
        let inferred = OrchestrationSnapshotComposer.inferredLLMRuntimePhase(
            observed: .idleReady,
            requestPhase: .queued,
            agenticPhase: .started
        )
        #expect(inferred == .idleReady)
    }

    @Test("infers waiting-for-tool-execution after model generation completes")
    func infersWaitingForToolExecution() {
        let inferred = OrchestrationSnapshotComposer.inferredAgenticPhase(
            observed: .llmGenerationCompleted,
            llmRuntimePhase: .idleReady,
            requestPhase: .queued
        )
        #expect(inferred == .waitingForToolExecution)
    }

    @Test("infers executing-tools while request is active after planning")
    func infersExecutingTools() {
        let inferred = OrchestrationSnapshotComposer.inferredAgenticPhase(
            observed: .llmGenerationCompleted,
            llmRuntimePhase: .idleReady,
            requestPhase: .active
        )
        #expect(inferred == .executingTools)
    }
}
