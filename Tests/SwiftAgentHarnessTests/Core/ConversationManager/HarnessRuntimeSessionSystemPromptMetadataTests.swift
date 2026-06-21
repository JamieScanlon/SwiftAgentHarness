import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessRuntimeSession — system prompt conversation metadata", .serialized)
struct HarnessRuntimeSessionSystemPromptMetadataTests {

    @Test("generateFullSystemPrompt includes current conversation id and start date")
    func includesConversationMetadataForSelectedConversation() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "prompt-meta-live")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        try await fixture.host.createConversation(with: model, userSystemPrompt: "You are helpful.")
        let conversationID = try #require(await fixture.host.currentConversationID)

        let prompt = try await fixture.host.generateFullSystemPrompt(
            conversationID: conversationID,
            withUserSystemPrompt: "Keep answers short."
        )
        #expect(prompt.contains("This conversation id is: \(conversationID.uuidString)"))
        #expect(prompt.contains("This conversation was started on: unknown") == false)

        let startDatePrefix = "This conversation was started on: "
        guard let startLine = prompt.split(separator: "\n").first(where: { $0.hasPrefix(startDatePrefix) }) else {
            Issue.record("Missing conversationStartDate line")
            return
        }

        let dateString = startLine.replacingOccurrences(of: startDatePrefix, with: "")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(formatter.date(from: dateString) != nil)
    }

    @Test("generateFullSystemPrompt uses system message timestamp as conversationStartDate")
    func usesSystemMessageTimestampAsConversationStartDate() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "prompt-meta-seeded")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel(name: "seeded:latest")
        let conversationID = UUID()
        let startDate = Date(timeIntervalSince1970: 1_710_000_000)
        var record = SessionCatalogRecord(
            id: conversationID,
            topic: nil,
            description: nil,
            messageCount: 0,
            updatedAt: startDate,
            createdAt: startDate,
            modelName: model.modelName,
            interactionModeRaw: InteractionMode.chat.rawValue
        )
        record.systemPrompt = "System prompt"
        try fixture.local.bootstrapEmptyConversation(record)
        let system = Message(id: UUID(), role: .system, content: "System prompt", timestamp: startDate, toolCalls: [])
        _ = try await fixture.stack.saveMessage(system, for: conversationID, resourceManager: nil, logger: nil)
        let user = Message(
            id: UUID(),
            role: .user,
            content: "Hello",
            timestamp: startDate.addingTimeInterval(120),
            toolCalls: []
        )
        _ = try await fixture.stack.saveMessage(user, for: conversationID, resourceManager: nil, logger: nil)
        try await fixture.host.resetConversationsFromCatalog(availableModels: [model])
        try await fixture.host.selectConversation(conversationID: conversationID)

        let prompt = try await fixture.host.generateFullSystemPrompt(
            conversationID: conversationID,
            withUserSystemPrompt: "Keep answers short."
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedDate = formatter.string(from: startDate)

        #expect(prompt.contains("This conversation id is: \(conversationID.uuidString)"))
        #expect(prompt.contains("This conversation was started on: \(expectedDate)"))
    }
}
