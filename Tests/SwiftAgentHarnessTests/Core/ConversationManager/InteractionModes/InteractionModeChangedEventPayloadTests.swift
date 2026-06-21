import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Interaction mode changed payload contract")
struct InteractionModeChangedEventPayloadTests {
    @Test("payload round-trips through ConversationEventCodec")
    func payloadRoundTrip() throws {
        let payload = InteractionModeChangedEventPayload(
            fromMode: "chat",
            toMode: "agent",
            fromProfileID: "chat",
            toProfileID: "custom-agent-profile",
            fromPhase: "plan",
            toPhase: "build",
            initiatedBy: "api",
            reason: "user_request"
        )

        let json = ConversationEventCodec.encode(payload)
        let decoded = try #require(
            ConversationEventCodec.decode(InteractionModeChangedEventPayload.self, from: json)
        )
        #expect(decoded == payload)
    }

    @Test("payload decode fails when profile ids are missing")
    func payloadDecodeFailsWithoutProfileIDs() {
        let legacyJSON = """
        {
          "fromMode":"chat",
          "toMode":"plan",
          "fromPhase":"plan",
          "toPhase":"plan",
          "initiatedBy":"api"
        }
        """
        let decoded = ConversationEventCodec.decode(InteractionModeChangedEventPayload.self, from: legacyJSON)
        #expect(decoded == nil)
    }
}
