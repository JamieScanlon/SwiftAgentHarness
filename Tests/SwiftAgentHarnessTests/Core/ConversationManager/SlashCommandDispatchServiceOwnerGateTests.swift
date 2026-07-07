import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum SlashCommandOwnerGateSupport {
    static func makeContainer() throws -> ModelContainer {
        try HarnessTestModelContainer.makeInMemory()
    }

    static func makeModel(name: String = "slash:owner-gate") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func transformWithOwnerOnlyToolDispatch(
        command: String = "queue",
        toolName: String = ConversationsToolProvider.listConversationsToolName,
        bypassTier: SlashCommandBypassTier = .always
    ) -> ConversationTransformConfiguration {
        ConversationTransformConfiguration(
            chat: .allEnabled,
            plan: .allEnabled,
            agent: .allEnabled,
            transformTimeoutSeconds: 1800,
            contextCompaction: .default,
            slashCommands: SlashCommandConfiguration(
                enabled: true,
                allowUnknownPassthrough: true,
                compactEnabled: true,
                skillSlashEnabled: true,
                toolDispatchCommands: [
                    .init(
                        command: command,
                        toolName: toolName,
                        argMode: .raw,
                        description: "Owner-only dispatch \(command) to \(toolName)",
                        ownerOnly: true,
                        bypassTier: bypassTier
                    ),
                ]
            )
        )
    }

    static func makeManager(
        container: ModelContainer,
        transform: ConversationTransformConfiguration
    ) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: transform,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }
}

@Suite("SlashCommandDispatchService owner gate", .serialized)
struct SlashCommandDispatchServiceOwnerGateTests {
    @Test("runSlashCommandIfNeeded rejects owner-only tool-dispatch when isOwner is false")
    func directDispatchRejectsNonOwner() async throws {
        let container = try SlashCommandOwnerGateSupport.makeContainer()
        let transform = SlashCommandOwnerGateSupport.transformWithOwnerOnlyToolDispatch()
        let manager = SlashCommandOwnerGateSupport.makeManager(container: container, transform: transform)
        let model = SlashCommandOwnerGateSupport.makeModel()

        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let rejected = try await manager.testing_runSlashCommandIfNeeded(
            "/queue list all",
            conversationID: conversationID,
            isOwner: false
        )
        #expect(rejected == nil)

        let allowed = try await manager.testing_runSlashCommandIfNeeded(
            "/queue list all",
            conversationID: conversationID,
            isOwner: true
        )
        #expect(allowed != nil)
    }

    @Test("protocol runSlashCommandIfNeeded resolves authenticated owner for owner-only tool-dispatch")
    func protocolDispatchResolvesAuthenticatedOwner() async throws {
        let container = try SlashCommandOwnerGateSupport.makeContainer()
        let transform = SlashCommandOwnerGateSupport.transformWithOwnerOnlyToolDispatch()
        let manager = SlashCommandOwnerGateSupport.makeManager(container: container, transform: transform)
        let model = SlashCommandOwnerGateSupport.makeModel(name: "slash:owner-gate-protocol")
        let ownerA = UUID()
        let ownerB = UUID()

        let conversationID = try await APISessionContext.$authenticatedOwnerAccountID.withValue(ownerA) {
            try await manager.createConversation(with: model, userSystemPrompt: "sys")
            return try #require(await manager.currentConversationID)
        }

        let rejected = try await APISessionContext.$authenticatedOwnerAccountID.withValue(ownerB) {
            try await manager.testing_runSlashCommandIfNeededViaDispatchingProtocol(
                "/queue list all",
                conversationID: conversationID
            )
        }
        #expect(rejected == nil)

        let allowed = try await APISessionContext.$authenticatedOwnerAccountID.withValue(ownerA) {
            try await manager.testing_runSlashCommandIfNeededViaDispatchingProtocol(
                "/queue list all",
                conversationID: conversationID
            )
        }
        #expect(allowed != nil)
    }

    @Test("drainPendingSlashCommandsIfNeeded re-checks owner for queued owner-only tool-dispatch")
    func drainRechecksOwnerForQueuedOwnerOnlyCommand() async throws {
        let container = try SlashCommandOwnerGateSupport.makeContainer()
        let transform = SlashCommandOwnerGateSupport.transformWithOwnerOnlyToolDispatch(bypassTier: .queued)
        let manager = SlashCommandOwnerGateSupport.makeManager(container: container, transform: transform)
        let model = SlashCommandOwnerGateSupport.makeModel(name: "slash:owner-gate-drain")
        let ownerA = UUID()
        let ownerB = UUID()

        let conversationID = try await APISessionContext.$authenticatedOwnerAccountID.withValue(ownerA) {
            try await manager.createConversation(with: model, userSystemPrompt: "sys")
            return try #require(await manager.currentConversationID)
        }

        await manager.testing_setSlashDispatchConversationState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started
        )

        _ = try await APISessionContext.$authenticatedOwnerAccountID.withValue(ownerA) {
            try await manager.testing_runSlashCommandIfNeeded(
                "/queue list all",
                conversationID: conversationID,
                skipQueue: false,
                isOwner: true
            )
        }

        #expect(await manager.testing_pendingSlashCommandCount(conversationID: conversationID) == 1)
        let messagesAfterQueue = try await manager.listCurrentMessages()
        #expect(messagesAfterQueue.contains { $0.role == .assistant && $0.content.contains("Queued:") })

        await manager.testing_setSlashDispatchConversationState(
            conversationID: conversationID,
            state: .idle,
            agenticPhase: .idle
        )

        await APISessionContext.$authenticatedOwnerAccountID.withValue(ownerB) {
            await manager.slashCommandDispatchService.drainPendingSlashCommandsIfNeeded(conversationID: conversationID)
        }

        #expect(await manager.testing_pendingSlashCommandCount(conversationID: conversationID) == 0)
        let messagesAfterDrain = try await manager.listCurrentMessages()
        #expect(messagesAfterDrain.count == messagesAfterQueue.count)
    }
}
