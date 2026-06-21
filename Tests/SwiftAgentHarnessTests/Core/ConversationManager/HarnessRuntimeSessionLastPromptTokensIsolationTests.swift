import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Validates the lifecycle of `HarnessRuntimeSession.lastPromptTokens` (and its sibling
/// `lastContextLimitTokens`) — the proactive trigger leans on these counters and the design
/// calls out two specific risk boundaries:
///
/// 1. Conversation-switch via `selectConversation` does NOT clear the counters; the actual
///    reset happens at the next orchestrator rebuild inside `setupOrchestrator`. Documenting
///    this directly so any future change that moves the reset earlier or later trips the test.
/// 2. The orchestrator-rebuild reset wipes all three sibling fields together. We exercise that
///    path through the internal `testing_resetContextTokenSnapshot()` seam.
private enum LastPromptTokensIsolationSupport {
    static func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    static func makeModel(name: String = "isolation:test") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }
}

@Suite("HarnessRuntimeSession lastPromptTokens isolation", .serialized)
struct HarnessRuntimeSessionLastPromptTokensIsolationTests {

    @Test("Testing setter and getter round-trip the value")
    func setterAndGetterRoundTrip() async throws {
        let container = try LastPromptTokensIsolationSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = LastPromptTokensIsolationSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversation = try #require(await runtimeSession.currentConversation())
        await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)

        await runtimeSession.testing_setLastPromptTokens(150_000)
        await runtimeSession.testing_setLastContextLimitTokens(200_000)

        let prompt = await runtimeSession.testing_currentLastPromptTokens()
        let limit = await runtimeSession.testing_currentLastContextLimitTokens()
        #expect(prompt == 150_000)
        #expect(limit == 200_000)
    }

    @Test("testing_resetContextTokenSnapshot clears prompt + limit + remaining together")
    func resetClearsAllSiblings() async throws {
        let container = try LastPromptTokensIsolationSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = LastPromptTokensIsolationSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversation = try #require(await runtimeSession.currentConversation())
        await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)

        await runtimeSession.testing_setLastPromptTokens(150_000)
        await runtimeSession.testing_setLastContextLimitTokens(200_000)
        await runtimeSession.testing_resetContextTokenSnapshot()

        let prompt = await runtimeSession.testing_currentLastPromptTokens()
        let limit = await runtimeSession.testing_currentLastContextLimitTokens()
        #expect(prompt == nil)
        #expect(limit == nil)
    }

    @Test("selectConversation alone does NOT clear lastPromptTokens (reset happens later in setupOrchestrator)")
    func selectConversationDoesNotClearLastPromptTokens() async throws {
        let container = try LastPromptTokensIsolationSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = LastPromptTokensIsolationSupport.makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys-A")
        let convA = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys-B")
        let convB = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.selectConversation(conversationID: convA)
        let conversationA = try #require(await runtimeSession.modelConversation(id: convA))
        await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversationA)
        await runtimeSession.testing_setLastPromptTokens(150_000)

        try await runtimeSession.selectConversation(conversationID: convB)
        let afterSelectB = await runtimeSession.testing_currentLastPromptTokens()
        #expect(afterSelectB == nil)

        try await runtimeSession.selectConversation(conversationID: convA)
        let afterSelectA = await runtimeSession.testing_currentLastPromptTokens()
        #expect(afterSelectA == 150_000)
    }

    @Test("After conversation-switch then reset, lastPromptTokens is nil (mirrors setupOrchestrator behaviour)")
    func resetAfterSwitchIsolatesConversations() async throws {
        let container = try LastPromptTokensIsolationSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = LastPromptTokensIsolationSupport.makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys-A")
        let convA = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys-B")
        let convB = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.selectConversation(conversationID: convA)
        let conversationA = try #require(await runtimeSession.modelConversation(id: convA))
        await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversationA)
        await runtimeSession.testing_setLastPromptTokens(150_000)

        try await runtimeSession.selectConversation(conversationID: convB)
        let conversationB = try #require(await runtimeSession.modelConversation(id: convB))
        await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversationB)
        await runtimeSession.testing_resetContextTokenSnapshot()

        let afterReset = await runtimeSession.testing_currentLastPromptTokens()
        #expect(afterReset == nil)

        try await runtimeSession.selectConversation(conversationID: convA)
        let convATokens = await runtimeSession.testing_currentLastPromptTokens()
        #expect(convATokens == nil)
    }

    @Test("Repeated reset is idempotent (no observable state, no crash)")
    func resetIsIdempotent() async throws {
        let container = try LastPromptTokensIsolationSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))

        await runtimeSession.testing_resetContextTokenSnapshot()
        await runtimeSession.testing_resetContextTokenSnapshot()

        let prompt = await runtimeSession.testing_currentLastPromptTokens()
        let limit = await runtimeSession.testing_currentLastContextLimitTokens()
        #expect(prompt == nil)
        #expect(limit == nil)
    }
}
