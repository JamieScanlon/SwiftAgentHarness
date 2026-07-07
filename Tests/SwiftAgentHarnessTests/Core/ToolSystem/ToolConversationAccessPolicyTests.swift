import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolConversationAccessPolicy")
struct ToolConversationAccessPolicyTests {

    @Test("strict tenancy resolveOwnerScope uses authenticated owner only")
    func strictResolveOwnerScopeUsesAuthenticatedOwnerOnly() {
        let authenticated = UUID()
        let callerOwner = UUID()
        let registryOwner = UUID()
        let caller = ModelConversation(
            id: UUID(),
            model: HarnessConversationTestFixtures.makeTestModel(),
            messages: [],
            createdAt: Date(),
            updatedAt: Date(),
            ownerAccountID: callerOwner
        )

        let scope = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: true,
            authenticatedOwnerAccountID: authenticated,
            callerConversation: caller,
            registryOwnerAccountID: registryOwner
        )
        #expect(scope == authenticated)

        let nilAuth = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: true,
            authenticatedOwnerAccountID: nil,
            callerConversation: caller,
            registryOwnerAccountID: registryOwner
        )
        #expect(nilAuth == nil)
    }

    @Test("loose tenancy resolveOwnerScope preserves fallback chain")
    func looseResolveOwnerScopeUsesFallbackChain() {
        let callerOwner = UUID()
        let registryOwner = UUID()
        let caller = ModelConversation(
            id: UUID(),
            model: HarnessConversationTestFixtures.makeTestModel(),
            messages: [],
            createdAt: Date(),
            updatedAt: Date(),
            ownerAccountID: callerOwner
        )

        let fromCaller = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: false,
            authenticatedOwnerAccountID: nil,
            callerConversation: caller,
            registryOwnerAccountID: registryOwner
        )
        #expect(fromCaller == callerOwner)

        let fromRegistry = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: false,
            authenticatedOwnerAccountID: nil,
            callerConversation: nil,
            registryOwnerAccountID: registryOwner
        )
        #expect(fromRegistry == registryOwner)
    }

    @Test("strict tenancy isOwnerAccessible fails closed when owner scope is nil")
    func strictOwnerAccessibleFailsClosedWithoutScope() {
        #expect(
            ToolConversationAccessPolicy.isOwnerAccessible(
                targetOwner: UUID(),
                ownerScope: nil,
                strictTenancy: true
            ) == false
        )
        #expect(
            ToolConversationAccessPolicy.isOwnerAccessible(
                targetOwner: UUID(),
                ownerScope: nil,
                strictTenancy: false
            ) == true
        )
    }

    @Test("strict tenancy list_conversations returns only authenticated owner rows")
    func strictTenancyListConversationsScopesToAuthenticatedOwner() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "tool-strict-tenant")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let ownerA = UUID()
        let ownerB = UUID()
        let convA = try fixture.stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "owner-a",
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            ownerAccountID: ownerA
        )
        let convB = try fixture.stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "owner-b",
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            ownerAccountID: ownerB
        )
        try fixture.stack.conversationManager.resetConversationsFromCatalog(availableModels: [model])
        try await fixture.host.resetConversationsFromCatalog(availableModels: [model])

        let domain = fixture.services.conversationDomainServices
        let strictToolData = ConversationToolDataService(
            catalog: domain.catalog,
            controlPlane: domain.controlPlane,
            agentRuntime: fixture.services.agentRuntimeSessionService,
            selection: fixture.services.selection,
            tenancyPolicy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        )
        let toolProvider = ConversationsToolProvider(dataProvider: strictToolData)

        let scoped = try await APISessionContext.$authenticatedOwnerAccountID.withValue(ownerA) {
            try await toolProvider.executeTool(
                ToolCall(
                    name: ConversationsToolProvider.listConversationsToolName,
                    arguments: .object([:]),
                    id: "list-scoped"
                )
            )
        }
        #expect(scoped.success == true)
        let scopedPayload = try #require(scoped.content.data(using: .utf8))
        let scopedRows = try JSONDecoder().decode([ConversationMetadata].self, from: scopedPayload)
        let scopedIDs = Set(scopedRows.compactMap { UUID(uuidString: $0.id) })
        #expect(scopedIDs.contains(convA.id))
        #expect(scopedIDs.contains(convB.id) == false)

        let empty = try await APISessionContext.$authenticatedOwnerAccountID.withValue(nil) {
            try await toolProvider.executeTool(
                ToolCall(
                    name: ConversationsToolProvider.listConversationsToolName,
                    arguments: .object([:]),
                    id: "list-empty"
                )
            )
        }
        #expect(empty.success == true)
        let emptyPayload = try #require(empty.content.data(using: .utf8))
        let emptyRows = try JSONDecoder().decode([ConversationMetadata].self, from: emptyPayload)
        #expect(emptyRows.isEmpty)
    }
}
