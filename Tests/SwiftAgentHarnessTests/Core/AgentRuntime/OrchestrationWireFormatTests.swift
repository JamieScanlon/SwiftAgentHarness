import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Orchestration REST/WebSocket JSON wire format")
struct OrchestrationWireFormatTests {
    @Test("JSONSerialization dictionary with orchestrationGeneration decodes to model")
    func jsonDictionaryWithGenerationRoundTrips() throws {
        let dict: [String: Any] = [
            "llmRuntimePhase": "idleReady",
            "agenticPhase": "executingTools",
            "llmRequestPhase": "streaming",
            "orchestrationGeneration": 42,
            "planHasBlockedTasks": false,
            "planAllTasksComplete": false
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ConversationOrchestrationState.self, from: data)
        #expect(decoded.orchestrationGeneration == 42)
        #expect(decoded.agenticPhase == .executingTools)
    }

    @Test("Encoded ConversationOrchestrationState includes generation for REST clients")
    func encodedJSONIncludesGenerationKey() throws {
        let state = ConversationOrchestrationState(
            agenticPhase: .llmCall,
            orchestrationGeneration: 99
        )
        let data = try JSONEncoder().encode(state)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["orchestrationGeneration"] as? Int == 99)
    }

    @Test("Conversation state payload carries orchestration harness when set")
    func conversationStatePayloadIncludesOrchestrationHarness() throws {
        let state = ConversationOrchestrationState(
            agenticPhase: .executingTools,
            harness: HarnessOrchestrationSupplement(
                milestone: "toolCallStarted",
                terminationCategory: "externalCancellation",
                terminationDetail: "user_stop_requested"
            )
        )
        let payload = ConversationStatePayload(
            conversationID: UUID(),
            exists: true,
            sessionSelected: true,
            orchestration: state,
            replayActive: false
        )
        let data = try JSONEncoder().encode(payload)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let orchestration = try #require(obj["orchestration"] as? [String: Any])
        let harness = try #require(orchestration["harness"] as? [String: Any])
        #expect(harness["milestone"] as? String == "toolCallStarted")
        #expect(harness["terminationCategory"] as? String == "externalCancellation")
        #expect(harness["terminationDetail"] as? String == "user_stop_requested")
    }

    @Test("A payload with no subAgentActivityPhase decodes as idle")
    func missingSubAgentActivityDecodesIdle() throws {
        let dict: [String: Any] = [
            "llmRuntimePhase": "idleReady",
            "agenticPhase": "idle",
            "planHasBlockedTasks": false,
            "planAllTasksComplete": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ConversationOrchestrationState.self, from: data)
        #expect(decoded.subAgentActivityPhase == .idle)
    }

    @Test("An unrecognized subAgentActivityPhase decodes as idle rather than failing the snapshot")
    func unknownSubAgentActivityDecodesIdle() throws {
        let dict: [String: Any] = [
            "llmRuntimePhase": "idleReady",
            "agenticPhase": "executingTools",
            "planHasBlockedTasks": false,
            "planAllTasksComplete": false,
            "subAgentActivityPhase": "somethingAddedLater",
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        // Decoding this field as the enum directly would *throw* on an unknown case, and that throw
        // fails the whole snapshot — a client on an older build would lose every status field the
        // day a case is added server-side, not just this one.
        let decoded = try JSONDecoder().decode(ConversationOrchestrationState.self, from: data)
        #expect(decoded.subAgentActivityPhase == .idle)
        #expect(decoded.agenticPhase == .executingTools)
    }

    @Test("Encoded ConversationOrchestrationState always carries subAgentActivityPhase")
    func encodedJSONIncludesSubAgentActivityKey() throws {
        let state = ConversationOrchestrationState(
            agenticPhase: .idle,
            subAgentActivityPhase: .working
        )
        let data = try JSONEncoder().encode(state)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["subAgentActivityPhase"] as? String == "working")
    }

    @Test("Sub-agent activity is a wire phase, so a change alone refreshes the topic")
    func subAgentActivityParticipatesInPhaseComparison() {
        let idle = ConversationOrchestrationState(agenticPhase: .idle, subAgentActivityPhase: .idle)
        let working = ConversationOrchestrationState(agenticPhase: .idle, subAgentActivityPhase: .working)
        #expect(idle.hasSameWireOrchestrationPhases(as: working) == false)
        #expect(idle.hasSameWireOrchestrationPhases(as: idle))
    }

    @Test("Sub-agent activity is not part of the mid-turn regression ordering")
    func subAgentActivityIsNotRankedForRegression() {
        let runID = UUID()
        let working = ConversationOrchestrationState(
            agenticPhase: .executingTools,
            currentRunID: runID,
            subAgentActivityPhase: .working
        )
        let settled = ConversationOrchestrationState(
            agenticPhase: .executingTools,
            currentRunID: runID,
            subAgentActivityPhase: .idle
        )
        // A delegate finishing mid-turn must not read as the parent's turn regressing — that would
        // freeze the parent's phases at their previous values for the rest of the run.
        #expect(settled.isRegressiveOrchestrationWireSnapshot(comparedTo: working) == false)
        #expect(working.isRegressiveOrchestrationWireSnapshot(comparedTo: settled) == false)
        #expect(working.wireOrchestrationActivityRank == settled.wireOrchestrationActivityRank)
    }
}
