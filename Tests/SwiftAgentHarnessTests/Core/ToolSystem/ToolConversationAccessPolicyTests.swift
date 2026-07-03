import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum ToolConversationAccessPolicyTestSupport {
    static func makeModel(name: String = "test-model") -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func makeConversation(
        id: UUID = UUID(),
        parentConversationID: UUID? = nil,
        ownerAccountID: UUID? = nil,
        metadata: JSON? = nil,
        lineageKind: ConversationLineageKind = .root,
        origin: ConversationOrigin = .user
    ) -> ModelConversation {
        let now = Date()
        return ModelConversation(
            id: id,
            model: makeModel(),
            messages: [],
            createdAt: now,
            updatedAt: now,
            topic: nil,
            description: nil,
            metadata: metadata,
            parentConversationID: parentConversationID,
            ownerAccountID: ownerAccountID,
            lineageKind: lineageKind,
            origin: origin
        )
    }

    static func metadata(id: UUID, owner: UUID, parent: UUID?) -> ConversationMetadata {
        ConversationMetadata(
            id: id.uuidString,
            modelName: "m",
            topic: nil,
            description: nil,
            messageCount: 0,
            createdAt: "2020-01-01T00:00:00Z",
            updatedAt: "2020-01-01T00:00:00Z",
            ownerAccountID: owner,
            parentConversationID: parent,
            lineageKind: parent == nil ? .root : .branch,
            origin: .user
        )
    }
}

@Suite("ToolConversationAccessPolicy")
struct ToolConversationAccessPolicyTests {
    @Test("resolveOwnerScope prefers JWT over caller conversation owner")
    func resolveOwnerScopePriority() {
        let jwtOwner = UUID()
        let callerOwner = UUID()
        let caller = ToolConversationAccessPolicyTestSupport.makeConversation(ownerAccountID: callerOwner)
        let resolved = ToolConversationAccessPolicy.resolveOwnerScope(
            authenticatedOwnerAccountID: jwtOwner,
            callerConversation: caller,
            registryOwnerAccountID: UUID()
        )
        #expect(resolved == jwtOwner)
    }

    @Test("resolveOwnerScope falls back to caller conversation owner")
    func resolveOwnerScopeCallerFallback() {
        let callerOwner = UUID()
        let caller = ToolConversationAccessPolicyTestSupport.makeConversation(ownerAccountID: callerOwner)
        let resolved = ToolConversationAccessPolicy.resolveOwnerScope(
            authenticatedOwnerAccountID: nil,
            callerConversation: caller,
            registryOwnerAccountID: UUID()
        )
        #expect(resolved == callerOwner)
    }

    @Test("isOwnerAccessible passes when owner scope is nil")
    func ownerAccessibleNilScope() {
        #expect(ToolConversationAccessPolicy.isOwnerAccessible(targetOwner: UUID(), ownerScope: nil))
    }

    @Test("isOwnerAccessible requires exact owner match when scope is set")
    func ownerAccessibleRequiresMatch() {
        let owner = UUID()
        #expect(ToolConversationAccessPolicy.isOwnerAccessible(targetOwner: owner, ownerScope: owner))
        #expect(!ToolConversationAccessPolicy.isOwnerAccessible(targetOwner: UUID(), ownerScope: owner))
        #expect(!ToolConversationAccessPolicy.isOwnerAccessible(targetOwner: nil, ownerScope: owner))
    }

    @Test("lineageRoot walks parent chain for branches")
    func lineageRootWalksParents() {
        let rootID = UUID()
        let branchID = UUID()
        let root = ToolConversationAccessPolicyTestSupport.makeConversation(id: rootID, lineageKind: .root)
        let branch = ToolConversationAccessPolicyTestSupport.makeConversation(
            id: branchID,
            parentConversationID: rootID,
            lineageKind: .branch
        )
        let lookup: [UUID: ModelConversation] = [rootID: root, branchID: branch]

        let branchRoot = ToolConversationAccessPolicy.lineageRoot(for: branch) { id in
            lookup[id]
        }
        #expect(branchRoot == rootID)
    }

    @Test("lineageRoot uses subAgentRootConversationID metadata")
    func lineageRootSubAgentMetadata() {
        let rootID = UUID()
        let subAgentID = UUID()
        let metadata: JSON = .object([
            "subAgentRootConversationID": .string(rootID.uuidString.lowercased()),
            "subAgentDepth": .integer(1),
        ])
        let subAgent = ToolConversationAccessPolicyTestSupport.makeConversation(
            id: subAgentID,
            parentConversationID: rootID,
            metadata: metadata,
            lineageKind: .subAgent,
            origin: .system
        )
        let root = ToolConversationAccessPolicy.lineageRoot(for: subAgent) { _ in nil }
        #expect(root == rootID)
    }

    @Test("isLineageAccessible allows self and same root siblings")
    func lineageAccessibleSameTree() {
        let rootID = UUID()
        let callerID = UUID()
        let siblingID = UUID()
        let callerScope = ConversationScope(
            selfID: callerID,
            parentID: rootID,
            rootID: rootID,
            lineageKind: .branch,
            origin: .user
        )
        #expect(
            ToolConversationAccessPolicy.isLineageAccessible(
                callerScope: callerScope,
                targetConversationID: callerID,
                callerLineageRoot: rootID,
                targetLineageRoot: rootID
            )
        )
        #expect(
            ToolConversationAccessPolicy.isLineageAccessible(
                callerScope: callerScope,
                targetConversationID: siblingID,
                callerLineageRoot: rootID,
                targetLineageRoot: rootID
            )
        )
    }

    @Test("isLineageAccessible denies unrelated roots when scope is set")
    func lineageAccessibleDeniesUnrelatedRoots() {
        let callerScope = ConversationScope(
            selfID: UUID(),
            parentID: nil,
            rootID: UUID(),
            lineageKind: .root,
            origin: .user
        )
        #expect(
            !ToolConversationAccessPolicy.isLineageAccessible(
                callerScope: callerScope,
                targetConversationID: UUID(),
                callerLineageRoot: UUID(),
                targetLineageRoot: UUID()
            )
        )
    }

    @Test("filterAccessibleMetadata applies owner and lineage filters")
    func filterAccessibleMetadata() {
        let owner = UUID()
        let otherOwner = UUID()
        let rootID = UUID()
        let branchID = UUID()
        let unrelatedID = UUID()
        let callerScope = ConversationScope(
            selfID: rootID,
            parentID: nil,
            rootID: rootID,
            lineageKind: .root,
            origin: .user
        )
        let rows: [ConversationMetadata] = [
            ToolConversationAccessPolicyTestSupport.metadata(id: rootID, owner: owner, parent: nil),
            ToolConversationAccessPolicyTestSupport.metadata(id: branchID, owner: owner, parent: rootID),
            ToolConversationAccessPolicyTestSupport.metadata(id: unrelatedID, owner: owner, parent: nil),
            ToolConversationAccessPolicyTestSupport.metadata(id: UUID(), owner: otherOwner, parent: nil),
        ]
        let filtered = ToolConversationAccessPolicy.filterAccessibleMetadata(
            rows,
            callerScope: callerScope,
            ownerScope: owner,
            callerLineageRoot: rootID
        )
        let ids = Set(filtered.map(\.id))
        #expect(ids.contains(rootID.uuidString))
        #expect(ids.contains(branchID.uuidString))
        #expect(!ids.contains(unrelatedID.uuidString))
        #expect(filtered.allSatisfy { $0.ownerAccountID == owner })
    }
}
