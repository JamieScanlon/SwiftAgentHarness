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
}
