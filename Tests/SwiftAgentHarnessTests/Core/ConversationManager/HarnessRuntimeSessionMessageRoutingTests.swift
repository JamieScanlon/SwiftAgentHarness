import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private func makeModel(name: String = "test:latest") -> Model {
    Model(
        protocol: .ollama,
        modelName: name,
        serverURL: URL(string: "http://localhost:11434")!,
        capabilities: [],
        modelProtocol: .ollama
    )
}

private func makeHarnessHost(label: String) throws -> HarnessRuntimeHostFixture {
    try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: label)
}

@Suite("HarnessRuntimeSession — message routing & currentMessages sync", .serialized)
struct HarnessRuntimeSessionMessageRoutingTests {

    @Test("selectConversation updates currentMessages to match the selected thread")
    func selectConversationSyncsPublishedCurrentMessages() async throws {
        let fixture = try makeHarnessHost(label: "routing-select")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let (idA, idB) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(host: fixture.host, model: model)
        let runtimeSession = fixture.host

        try await runtimeSession.selectConversation(conversationID: idA)
        let whenA = try await runtimeSession.listCurrentMessages()
        #expect(whenA.contains { $0.role == .user && $0.content == "UserA-only" })
        #expect(whenA.count == 2)

        try await runtimeSession.selectConversation(conversationID: idB)
        let whenB = try await runtimeSession.listCurrentMessages()
        #expect(whenB.contains { $0.role == .user && $0.content == "UserB-only" })
        #expect(whenB.count == 2)

        try await runtimeSession.selectConversation(conversationID: idA)
        let whenABack = try await runtimeSession.listCurrentMessages()
        #expect(whenABack.contains { $0.role == .user && $0.content == "UserA-only" })
        #expect(whenABack.count == 2)
    }

    @Test("orchestrator messages append to orchestratorConversationID when selection differs")
    func orchestratorTargetWinsOverCurrentSelection() async throws {
        let fixture = try makeHarnessHost(label: "routing-orchestrator")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let (idA, idB) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(host: fixture.host, model: model)
        let runtimeSession = fixture.host

        try await runtimeSession.selectConversation(conversationID: idA)
        await runtimeSession.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .assistant, content: "only-on-A", timestamp: Date(), toolCalls: []),
        ])
        let convsAfterFirst = await runtimeSession.listConversationInfo()
        let countA = convsAfterFirst.first(where: { $0.id == idA })?.messages.count ?? 0
        #expect(countA == 3)

        // Select B while A still owns the active streaming run (simulates REST switch mid-send on A).
        try await runtimeSession.selectConversation(conversationID: idB)
        let conversationA = try #require(await runtimeSession.modelConversation(id: idA))
        await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversationA)
        await runtimeSession.testing_setActiveStreamingRun(conversationID: idA, runID: UUID())
        defer { Task { await runtimeSession.testing_setActiveStreamingRun(conversationID: nil, runID: nil) } }

        await runtimeSession.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .assistant, content: "second-on-A", timestamp: Date(), toolCalls: []),
        ])

        let convs = await runtimeSession.listConversationInfo()
        let messagesA = convs.first(where: { $0.id == idA })?.messages ?? []
        let messagesB = convs.first(where: { $0.id == idB })?.messages ?? []

        #expect(messagesA.contains { $0.content == "second-on-A" })
        #expect(messagesA.count == 4)
        #expect(messagesB.count == 2)

        // Visible thread is still B; must not include A's orchestrator lines.
        let visible = try await runtimeSession.listCurrentMessages()
        #expect(visible.count == 2)
        #expect(visible.contains { $0.content == "UserB-only" })
        #expect(visible.contains { $0.content == "second-on-A" } == false)
    }

    /// Regression: first projection after appending must use the post-append transcript; otherwise
    /// `ConversationEventProjector` can drop newly appended rows and `currentMessages` stays stuck
    /// after a large tool result (UI shows only the tool row while the server continues).
    @Test("projected currentMessages includes assistant after large tool append on same thread")
    func projectedCurrentMessagesIncludesAssistantAfterLargeToolAppend() async throws {
        let fixture = try makeHarnessHost(label: "routing-large-tool")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let (idA, _) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(host: fixture.host, model: model)
        let runtimeSession = fixture.host
        try await runtimeSession.selectConversation(conversationID: idA)

        let bulky = String(repeating: "x", count: 8000)
        let toolID = UUID()
        let assistantID = UUID()
        let toolMsg = Message(
            id: toolID,
            role: .tool,
            content: bulky,
            timestamp: Date(),
            toolCalls: [],
            toolCallId: "call-regression-1"
        )
        let assistantMsg = Message(
            id: assistantID,
            role: .assistant,
            content: "after-tool-body",
            timestamp: Date(),
            toolCalls: []
        )

        await runtimeSession.testing_applyOrchestratorMessages([toolMsg, assistantMsg])

        let projected = await runtimeSession.currentMessages
        #expect(projected.contains { $0.id == toolID })
        #expect(projected.contains { $0.id == assistantID })

        let toolIndex = projected.firstIndex { $0.id == toolID }
        let assistantIndex = projected.firstIndex { $0.id == assistantID }
        #expect(toolIndex != nil && assistantIndex != nil)
        #expect(toolIndex! < assistantIndex!)

        let raw = try await runtimeSession.listCurrentMessages()
        #expect(raw.contains { $0.id == toolID })
        #expect(raw.contains { $0.id == assistantID })
    }

}
