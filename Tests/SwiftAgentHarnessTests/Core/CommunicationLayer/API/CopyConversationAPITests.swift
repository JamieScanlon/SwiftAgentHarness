import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ConvoRequest API")
struct ConvoRequestAPITests {

    @Test("ConvoRequest encodes and decodes topic and description")
    func convoRequestCodableWithMetadata() throws {
        let request = ConvoRequest(
            modelRef: "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
            userSystemPrompt: "System prompt",
            topic: "Travel plans",
            description: "Ideas for a one-week trip.",
            metadata: nil,
            interactionMode: "agent",
            modeProfileID: nil,
            cwd: nil
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ConvoRequest.self, from: data)

        #expect(decoded.modelRef == request.modelRef)
        #expect(decoded.userSystemPrompt == request.userSystemPrompt)
        #expect(decoded.topic == "Travel plans")
        #expect(decoded.description == "Ideas for a one-week trip.")
        #expect(decoded.interactionMode == "agent")
    }

    @Test("ConvoRequest decodes with nil optional metadata")
    func convoRequestCodableWithoutMetadata() throws {
        let json = """
        {
            "modelRef": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
            "userSystemPrompt": "System prompt"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ConvoRequest.self, from: data)

        #expect(decoded.modelRef == "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        #expect(decoded.topic == nil)
        #expect(decoded.description == nil)
        #expect(decoded.interactionMode == nil)
    }
}
