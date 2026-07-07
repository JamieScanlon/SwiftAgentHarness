import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SlashCommandDispatchService control input boundary")
struct SlashCommandDispatchServiceControlInputBoundaryTests {
    private static func makeContainer() throws -> ModelContainer {
        try HarnessTestModelContainer.makeInMemory()
    }

    private static func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "control-input:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    private static func makeManager(container: ModelContainer) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }

    @Test("Inline /think high returns stripped prose and turn override without persisting")
    func inlineHintBoundaryOutcome() async throws {
        let container = try Self.makeContainer()
        let manager = Self.makeManager(container: container)
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let outcome = try await manager.slashCommandDispatchService.processControlInputBoundary(
            text: "/think high summarize the logs",
            conversationID: conversationID,
            trustClass: TrustPolicyClass.trusted,
            senderLabel: nil as String?
        )

        guard case let .continueTurn(modelText, patch, preTurnAck) = outcome else {
            Issue.record("Expected continueTurn outcome")
            return
        }
        #expect(modelText == "summarize the logs")
        #expect(patch.turnThinkingOverride == ThinkingConfig.level(.high, budgetTokens: nil))
        #expect(preTurnAck == nil)

        let conversation = try #require(await manager.modelConversation(id: conversationID))
        #expect(conversation.routingPrefs?.modelOptions?.thinkingConfig == nil)
    }

    @Test("Low-trust input falls through privileged inline directives")
    func lowTrustInlineHintPassthrough() async throws {
        let container = try Self.makeContainer()
        let manager = Self.makeManager(container: container)
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let outcome = try await manager.slashCommandDispatchService.processControlInputBoundary(
            text: "/think high summarize the logs",
            conversationID: conversationID,
            trustClass: .lowTrust,
            senderLabel: nil as String?
        )

        guard case .passthrough = outcome else {
            Issue.record("Expected passthrough for low-trust privileged input")
            return
        }

        let conversation = try #require(await manager.modelConversation(id: conversationID))
        #expect(conversation.routingPrefs?.modelOptions?.thinkingConfig == nil)
    }

    @Test("Low-trust input falls through directive-only privileged commands")
    func lowTrustDirectiveOnlyPassthrough() async throws {
        let container = try Self.makeContainer()
        let manager = Self.makeManager(container: container)
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let outcome = try await manager.slashCommandDispatchService.processControlInputBoundary(
            text: "/think high",
            conversationID: conversationID,
            trustClass: .lowTrust,
            senderLabel: nil as String?
        )

        guard case .passthrough = outcome else {
            Issue.record("Expected passthrough for low-trust directive-only input")
            return
        }
    }

    @Test("Partial tenancy denies owner when conversation is bound but auth context is missing")
    func partialTenancyDeniesOwnerWithoutAuth() async throws {
        let container = try Self.makeContainer()
        let manager = Self.makeManager(container: container)
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        var conversation = try #require(await manager.modelConversation(id: conversationID))
        conversation.ownerAccountID = UUID()
        await manager.conversationMessagingRuntimeService.update(conversation: conversation)

        let auth = await APISessionContext.$authenticatedOwnerAccountID.withValue(nil) {
            await manager.slashCommandDispatchService.makeControlInputAuthorization(
                conversationID: conversationID,
                trustClass: .trusted
            )
        }
        #expect(auth.isOwner == false)
    }

    @Test("Local single-tenant mode treats missing owner binding as owner")
    func localSingleTenantOwner() async throws {
        let container = try Self.makeContainer()
        let manager = Self.makeManager(container: container)
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let auth = await APISessionContext.$authenticatedOwnerAccountID.withValue(nil) {
            await manager.slashCommandDispatchService.makeControlInputAuthorization(
                conversationID: conversationID,
                trustClass: .trusted
            )
        }
        #expect(auth.isOwner == true)
    }

    @Test("Nil trust class defaults to low trust in authorization")
    func nilTrustClassDefaultsLowTrust() async throws {
        let container = try Self.makeContainer()
        let manager = Self.makeManager(container: container)
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let auth = await manager.slashCommandDispatchService.makeControlInputAuthorization(
            conversationID: conversationID,
            trustClass: nil
        )
        #expect(auth.trustClass == .lowTrust)
        #expect(auth.allowsPrivilegedInput == false)
    }
}
