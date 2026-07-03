import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

// MARK: - Helpers

private func makeInMemoryContainer() throws -> ModelContainer {
    try HarnessConversationTestFixtures.makeInMemoryContainer()
}

private func makeModel(name: String = "test:latest") -> Model {
    HarnessConversationTestFixtures.makeTestModel(name: name)
}

private func seedMultiMessageConversation(
    host: HarnessRuntimeSession,
    model: Model,
    systemPrompt: String = "System prompt",
    availableModels: [Model]
) async throws -> UUID {
    let user = Message(id: UUID(), role: .user, content: "User message", timestamp: Date(), toolCalls: [])
    let assistant = Message(
        id: UUID(),
        role: .assistant,
        content: "Assistant reply",
        timestamp: Date(),
        toolCalls: [ToolCall(name: "some_tool", arguments: .object([:]), id: "tc-1")]
    )
    let tool = Message(id: UUID(), role: .tool, content: "Tool result", timestamp: Date(), toolCalls: [], toolCallId: "tc-1")
    return try await HarnessConversationTestFixtures.seedRegistryConversation(
        host: host,
        model: model,
        systemPrompt: systemPrompt,
        extraMessages: [user, assistant, tool],
        availableModels: availableModels
    )
}

private func writeConversationFixtureFile(
    conversationID: UUID,
    relativePath: String,
    contents: String
) throws -> URL {
    let directoryURL = AgentPlanStore.conversationDirectoryURL(for: conversationID)
    let fileURL = directoryURL.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: fileURL)
    return fileURL
}

// MARK: - Tests

@Suite("HarnessRuntimeSession read-only conversations")
struct HarnessRuntimeSessionReadOnlyConversationTests {

    @Test("resetConversationsFromCatalog includes conversations with unavailable models as read-only")
    func resetConversationsIncludesUnavailableModels() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "readonly-unavailable")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unavailable = Model(
            id: UUID(),
            protocol: .ollama,
            modelName: "removed:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: unavailable,
            availableModels: []
        )

        let conversations = await fixture.host.listConversationInfo()
        #expect(conversations.count == 1)
        #expect(conversations[0].isModelAvailable == false)
        #expect(conversations[0].modelName == "removed:latest")
        #expect(conversations[0].model.modelName == "removed:latest")
    }

    @Test("resetConversationsFromCatalog marks available-model conversations as isModelAvailable true")
    func resetConversationsMarksAvailableModels() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "readonly-available")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "available:latest")
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(host: fixture.host, model: model)

        let conversations = await fixture.host.listConversationInfo()
        #expect(conversations.count == 1)
        #expect(conversations[0].isModelAvailable == true)
        #expect(conversations[0].modelName == "available:latest")
    }

    @Test("resetConversationsFromCatalog mixes available and unavailable conversations")
    func resetConversationsMixesAvailableAndUnavailable() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "readonly-mixed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let availableModel = makeModel(name: "available:latest")
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(host: fixture.host, model: availableModel)
        let removed = Model(
            id: UUID(),
            protocol: .ollama,
            modelName: "removed:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: removed,
            availableModels: [availableModel]
        )

        let conversations = await fixture.host.listConversationInfo()
        #expect(conversations.count == 2)
        let availableConv = conversations.first { $0.modelName == "available:latest" }
        let unavailableConv = conversations.first { $0.modelName == "removed:latest" }
        #expect(availableConv?.isModelAvailable == true)
        #expect(unavailableConv?.isModelAvailable == false)
    }

    @Test("sendMessageAndStreamResponse throws modelUnavailable for read-only conversation")
    func sendMessageThrowsModelUnavailable() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "readonly-send")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let removed = makeModel(name: "removed:latest")
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: removed,
            availableModels: []
        )
        let conversations = await fixture.host.listConversationInfo()
        #expect(conversations.count == 1)
        try await fixture.host.selectConversation(conversationID: conversations[0].id)

        var didThrow = false
        do {
            let stream = try await fixture.host.sendMessageAndStreamResponse("hello", images: [], conversationID: conversations[0].id)
            _ = await HarnessAsyncTestSupport.drain(stream.partialContent)
        } catch ConversationServiceError.modelUnavailable {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test("resetConversationsFromCatalog preserves message order")
    func resetConversationsPreservesMessageOrder() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "readonly-order")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        _ = try await HarnessConversationTestFixtures.seedRegistryConversationWithStaggeredMessages(
            host: fixture.host,
            model: model
        )

        let conversations = await fixture.host.listConversationInfo()
        #expect(conversations.count == 1)
        let roles = conversations[0].messages.map { $0.role }
        let expected: [MessageRole] = [.system, .user, .assistant, .tool]
        #expect(roles == expected)
    }

    @Test("resetConversationsFromCatalog returns empty when cache is empty")
    func resetConversationsEmptyCache() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "readonly-empty")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.host.resetConversationsFromCatalog(availableModels: [])
        let conversations = await fixture.host.listConversationInfo()
        #expect(conversations.isEmpty)
    }

    @Test("resetConversationsFromCatalog uses openAIAPI for unknown protocol type")
    func resetConversationsUnknownProtocolDefaultsToOpenAIAPI() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "readonly-unknown-protocol")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conversationID = UUID()
        try fixture.local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: conversationID,
                topic: nil,
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "weird:model",
                interactionModeRaw: InteractionMode.chat.rawValue
            )
        )
        let system = Message(id: UUID(), role: .system, content: "x", timestamp: Date(), toolCalls: [])
        _ = try await fixture.stack.saveMessage(system, for: conversationID, resourceManager: nil, logger: nil)
        try await fixture.host.resetConversationsFromCatalog(availableModels: [])

        let conversations = await fixture.host.listConversationInfo()
        #expect(conversations.count == 1)
        #expect(conversations[0].model.modelProtocol == .openAIAPI)
        #expect(conversations[0].modelName == "weird:model")
    }

    // MARK: - copyConversation

    @Test("copyConversation creates new conversation with same messages")
    func copyConversationCreatesNewWithSameMessages() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-same")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(host: fixture.host, model: model)
        let sourceConvos = await fixture.host.listConversationInfo()
        #expect(sourceConvos.count == 1)
        let sourceID = sourceConvos[0].id
        let sourceMessageCount = sourceConvos[0].messages.count

        let newModel = Model(
            id: UUID(),
            protocol: .ollama,
            modelName: "target:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        try await fixture.host.copyConversation(from: sourceID, to: newModel, systemPrompt: "New prompt")

        let allConvos = await fixture.host.listConversationInfo()
        #expect(allConvos.count == 2)
        let copied = allConvos.first { $0.modelName == "target:latest" }
        #expect(copied != nil)
        #expect(copied?.systemPrompt == "New prompt")
        #expect(copied?.isModelAvailable == true)
        #expect(copied?.messages.count == sourceMessageCount)
    }

    @Test("copyConversation throws conversationNotFound for invalid source ID")
    func copyConversationThrowsNotFoundForInvalidSource() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-not-found")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.host.resetConversationsFromCatalog(availableModels: [])

        let fakeSourceID = UUID()
        let targetModel = makeModel(name: "target:latest")

        var didThrow = false
        do {
            try await fixture.host.copyConversation(from: fakeSourceID, to: targetModel, systemPrompt: "New")
        } catch ConversationServiceError.conversationNotFound {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test("copyConversation from read-only conversation works")
    func copyConversationFromReadOnlyWorks() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-readonly")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let removed = Model(
            id: UUID(),
            protocol: .ollama,
            modelName: "removed:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        _ = try await seedMultiMessageConversation(
            host: fixture.host,
            model: removed,
            systemPrompt: "Old prompt",
            availableModels: []
        )

        let sourceConvos = await fixture.host.listConversationInfo()
        #expect(sourceConvos.count == 1)
        #expect(sourceConvos[0].isModelAvailable == false)

        let targetModel = makeModel(name: "target:latest")
        try await fixture.host.copyConversation(from: sourceConvos[0].id, to: targetModel, systemPrompt: "Transferred prompt")

        let allConvos = await fixture.host.listConversationInfo()
        #expect(allConvos.count == 2)
        let copied = allConvos.first { $0.modelName == "target:latest" }
        #expect(copied != nil)
        #expect(copied?.isModelAvailable == true)
        #expect(copied?.systemPrompt == "Transferred prompt")
        #expect(copied?.messages.count == 4)
    }

    @Test("copyConversation preserves all message roles (user, assistant, tool)")
    func copyConversationPreservesMessageRoles() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-roles")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        let sourceID = try await seedMultiMessageConversation(
            host: fixture.host,
            model: model,
            systemPrompt: "Original",
            availableModels: [model]
        )

        let targetModel = Model(id: UUID(), protocol: .ollama, modelName: "target:latest", serverURL: URL(string: "http://localhost:11434")!, capabilities: [], modelProtocol: .ollama)
        try await fixture.host.copyConversation(from: sourceID, to: targetModel, systemPrompt: "New system")

        let allConvos = await fixture.host.listConversationInfo()
        let copied = allConvos.first { $0.modelName == "target:latest" }!
        let roles = copied.messages.map { $0.role }
        #expect(roles.contains(.system))
        #expect(roles.contains(.user))
        #expect(roles.contains(.assistant))
        #expect(roles.contains(.tool))
    }

    @Test("copyConversation preserves message order")
    func copyConversationPreservesMessageOrder() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-order")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        let sourceID = try await seedMultiMessageConversation(
            host: fixture.host,
            model: model,
            systemPrompt: "Original",
            availableModels: [model]
        )
        let sourceRoles = (await fixture.host.listConversationInfo()).first { $0.id == sourceID }!.messages.map { $0.role }

        let targetModel = Model(id: UUID(), protocol: .ollama, modelName: "target:latest", serverURL: URL(string: "http://localhost:11434")!, capabilities: [], modelProtocol: .ollama)
        try await fixture.host.copyConversation(from: sourceID, to: targetModel, systemPrompt: "New system")

        let copied = (await fixture.host.listConversationInfo()).first { $0.modelName == "target:latest" }!
        let copiedRoles = copied.messages.map { $0.role }
        #expect(copiedRoles == sourceRoles)
    }

    @Test("copyConversation with empty system prompt")
    func copyConversationWithEmptySystemPrompt() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-empty-prompt")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(host: fixture.host, model: model)
        let sourceID = (await fixture.host.listConversationInfo()).first!.id

        let targetModel = makeModel(name: "target:latest")
        try await fixture.host.copyConversation(from: sourceID, to: targetModel, systemPrompt: "")

        let copied = (await fixture.host.listConversationInfo()).first { $0.modelName == "target:latest" }!
        #expect(copied.systemPrompt == "")
        #expect(copied.messages.first { $0.role == .system }?.content == "")
    }

    @Test("copyConversation copies messages with image resources")
    func copyConversationCopiesImageResources() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-image")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        let sourceID = try await HarnessConversationTestFixtures.seedRegistryConversationWithImageUserMessage(
            host: fixture.host,
            local: fixture.local,
            model: model
        )

        let targetModel = makeModel(name: "target:latest")
        try await fixture.host.copyConversation(from: sourceID, to: targetModel, systemPrompt: "New")

        let copied = (await fixture.host.listConversationInfo()).first { $0.modelName == "target:latest" }!
        let userMsg = copied.messages.first { $0.role == .user }
        #expect(userMsg != nil)
        #expect(userMsg?.images.count == 1)
        #expect(userMsg?.images.first?.name == "test.png")
    }

    @Test("copyConversation selects the new conversation")
    func copyConversationSelectsNewConversation() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-select")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        let sourceID = try await seedMultiMessageConversation(host: fixture.host, model: model, availableModels: [model])
        try await fixture.host.selectConversation(conversationID: sourceID)

        let targetModel = makeModel(name: "target:latest")
        try await fixture.host.copyConversation(from: sourceID, to: targetModel, systemPrompt: "New")

        let currentID = await fixture.host.currentConversationID
        let allConvos = await fixture.host.listConversationInfo()
        let copied = allConvos.first { $0.modelName == "target:latest" }!
        #expect(currentID == copied.id)
    }

    @Test("copyConversation preserves tool calls and response format")
    func copyConversationPreservesToolCallsAndResponseFormat() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-tool-format")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "Content",
            timestamp: Date(),
            toolCalls: [
                ToolCall(name: "tool_a", arguments: .object([:]), id: "ta"),
                ToolCall(name: "tool_b", arguments: .object([:]), id: "tb"),
            ],
            responseFormat: "json_object"
        )
        let sourceID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [assistant]
        )
        let targetModel = makeModel(name: "target:latest")
        try await fixture.host.copyConversation(from: sourceID, to: targetModel, systemPrompt: "New")

        let copied = (await fixture.host.listConversationInfo()).first { $0.modelName == "target:latest" }!
        let assistantMsg = copied.messages.first { $0.role == .assistant }
        #expect(assistantMsg?.toolCalls.count == 2)
        #expect(assistantMsg?.toolCalls.map(\.name).sorted() == ["tool_a", "tool_b"])
        #expect(assistantMsg?.responseFormat == "json_object")
    }

    @Test("copyConversation also copies ~/.swiftAgentHarness/conversations/<id> files")
    func copyConversationCopiesConversationDirectoryFiles() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-dir")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceModel = makeModel(name: "source:latest")
        let sourceID = try await seedMultiMessageConversation(host: fixture.host, model: sourceModel, availableModels: [sourceModel])
        let sourceFile = try writeConversationFixtureFile(
            conversationID: sourceID,
            relativePath: "attachments/notes.txt",
            contents: "artifact payload"
        )
        defer { _ = AgentPlanStore.removeConversationDirectory(for: sourceID) }

        let targetModel = makeModel(name: "target:latest")
        try await fixture.host.copyConversation(from: sourceID, to: targetModel, systemPrompt: "New prompt")
        let copiedConversation = try #require((await fixture.host.listConversationInfo()).first { $0.modelName == "target:latest" })
        defer { _ = AgentPlanStore.removeConversationDirectory(for: copiedConversation.id) }

        let copiedFile = AgentPlanStore.conversationDirectoryURL(for: copiedConversation.id)
            .appendingPathComponent("attachments/notes.txt")
        #expect(FileManager.default.fileExists(atPath: sourceFile.path))
        #expect(FileManager.default.fileExists(atPath: copiedFile.path))
        let copiedContents = try String(contentsOf: copiedFile, encoding: .utf8)
        #expect(copiedContents == "artifact payload")
    }

    @Test("deleteConversation removes ~/.swiftAgentHarness/conversations/<id> directory")
    func deleteConversationRemovesConversationDirectory() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "delete-dir")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        let conversationID = try await seedMultiMessageConversation(host: fixture.host, model: model, availableModels: [model])
        _ = try writeConversationFixtureFile(
            conversationID: conversationID,
            relativePath: "state/tool-output.json",
            contents: "{\"ok\":true}"
        )
        let conversationDirectory = AgentPlanStore.conversationDirectoryURL(for: conversationID)
        #expect(FileManager.default.fileExists(atPath: conversationDirectory.path))

        try await fixture.host.deleteConversation(conversationID: conversationID)

        #expect(!FileManager.default.fileExists(atPath: conversationDirectory.path))
    }

    @Test("ConversationServiceError modelUnavailable case exists")
    func modelUnavailableErrorCaseExists() {
        let error = ConversationServiceError.modelUnavailable
        if case .modelUnavailable = error {
            // Pass
        } else {
            Issue.record("Expected modelUnavailable case")
        }
    }
}
