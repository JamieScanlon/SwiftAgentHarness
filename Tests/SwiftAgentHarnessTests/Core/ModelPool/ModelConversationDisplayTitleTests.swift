import Foundation
import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("ModelConversation display title")
struct ModelConversationDisplayTitleTests {
    @Test("displayTitle prefers topic then user message then other roles")
    func displayTitleFallbackOrder() {
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "test",
            serverURL: URL(string: "http://localhost:8080/api")!
        )
        let withTopic = ModelConversation(id: UUID(), model: model, topic: "Explicit topic")
        #expect(withTopic.displayTitle == "Explicit topic")

        let userOnly = ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "Hello from user")]
        )
        #expect(userOnly.displayTitle == "Hello from user")

        let assistantOnly = ModelConversation(
            id: UUID(),
            model: model,
            messages: [
                Message(id: UUID(), role: .system, content: "sys"),
                Message(id: UUID(), role: .assistant, content: "Assistant opener"),
            ]
        )
        #expect(assistantOnly.displayTitle == "Assistant opener")
    }
}
