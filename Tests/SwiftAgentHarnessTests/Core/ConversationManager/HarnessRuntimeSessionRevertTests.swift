import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessRuntimeSession revert")
struct HarnessRuntimeSessionRevertTests {
    private func makeHarnessHost(label: String) throws -> (
        host: HarnessRuntimeSession,
        harness: LocalHarnessSessionPersistence,
        root: URL
    ) {
        let fixture = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: label)
        let host = HarnessRuntimeSession(
            container: fixture.stack.modelContainer,
            harnessSessionPersistenceOverride: fixture.local
        )
        return (host, fixture.local, fixture.root)
    }

    @Test("revertToUserMessageAndStreamResponse throws invalidRevertTarget for unknown message id")
    func unknownMessageID() async throws {
        let fixture = try makeHarnessHost(label: "revert-unknown")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = fixture.host
        try await host.createConversation(with: HarnessConversationTestFixtures.makeTestModel(name: "revert-test"), userSystemPrompt: "S")
        let convID = try #require(await host.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "Hi", timestamp: Date(), toolCalls: [])
        await host.testing_applyOrchestratorMessages([userMessage])

        await #expect(throws: ConversationServiceError.invalidRevertTarget) {
            try await host.revertToUserMessageAndStreamResponse(conversationID: convID, messageID: UUID())
        }
    }

    @Test("revertToUserMessageAndStreamResponse throws invalidRevertTarget when anchor is not user role")
    func nonUserAnchor() async throws {
        let fixture = try makeHarnessHost(label: "revert-non-user")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = fixture.host
        try await host.createConversation(with: HarnessConversationTestFixtures.makeTestModel(name: "revert-test"), userSystemPrompt: "S")
        let convID = try #require(await host.currentConversationID)

        await #expect(throws: ConversationServiceError.invalidRevertTarget) {
            let systemID = try #require(
                await host.listConversationInfo().first(where: { $0.id == convID })?.messages.first(where: { $0.role == .system })?.id
            )
            try await host.revertToUserMessageAndStreamResponse(conversationID: convID, messageID: systemID)
        }
    }
}
