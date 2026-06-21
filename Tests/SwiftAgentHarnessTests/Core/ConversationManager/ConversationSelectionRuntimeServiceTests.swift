import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationSelectionRuntimeService")
struct ConversationSelectionRuntimeServiceTests {

    @Test("selectConversation updates current conversation and projected messages")
    func selectConversationUpdatesMirror() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "selection-runtime-select")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = Model(
            protocol: .ollama,
            modelName: "test:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        let (conversationID, _) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(
            host: fixture.host,
            model: model
        )
        let service = fixture.services.conversationSelectionRuntimeService
        try await service.selectConversation(conversationID: conversationID)
        #expect(await service.currentConversationID == conversationID)
        #expect(await service.currentMessages.isEmpty == false)
    }

    @Test("wireMessageStream yields updates when current messages change")
    func messageStreamYieldsOnCurrentMessagesChange() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "selection-runtime-stream")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = Model(
            protocol: .ollama,
            modelName: "test:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        let (conversationID, _) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(
            host: fixture.host,
            model: model
        )
        let service = fixture.services.conversationSelectionRuntimeService
        try await service.selectConversation(conversationID: conversationID)
        let initial = await service.currentMessages
        let stream = AsyncStream<[Message]>.makeStream()
        await service.wireMessageStream(continuation: stream.continuation, initial: initial)

        let updated = initial + [
            Message(id: UUID(), role: .assistant, content: "updated", timestamp: Date())
        ]
        await service.setCurrentMessagesIfSelected(conversationID: conversationID, messages: updated)

        var iterator = stream.stream.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.count == initial.count)
        let second = try #require(await iterator.next())
        #expect(second.count == updated.count)
        #expect(second.last?.content == "updated")
        await service.cancelMessageStreamBridge()
    }
}
