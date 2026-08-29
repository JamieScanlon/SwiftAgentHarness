import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationOwnerResolution")
struct ConversationOwnerResolutionTests {
    @Test("owned conversation matches its authenticated owner")
    func ownerMatches() {
        let owner = UUID()
        #expect(ConversationOwnerResolution.isOwner(
            conversationOwnerAccountID: owner,
            authenticatedOwnerAccountID: owner
        ))
    }

    @Test("owned conversation rejects a different authenticated principal")
    func ownerMismatch() {
        #expect(!ConversationOwnerResolution.isOwner(
            conversationOwnerAccountID: UUID(),
            authenticatedOwnerAccountID: UUID()
        ))
    }

    /// The partial-tenancy case: a row that names an owner, reached with no credential, is not
    /// owner-operated. Mirrors `SlashCommandDispatchServiceControlInputBoundaryTests`.
    @Test("owned conversation rejects an unauthenticated caller")
    func ownedButUnauthenticated() {
        #expect(!ConversationOwnerResolution.isOwner(
            conversationOwnerAccountID: UUID(),
            authenticatedOwnerAccountID: nil
        ))
    }

    /// Local single-tenant: nobody owns the row and nobody is authenticated, so the only party
    /// present is the operator.
    @Test("unowned conversation with no principal is owner-operated")
    func unownedUnauthenticated() {
        #expect(ConversationOwnerResolution.isOwner(
            conversationOwnerAccountID: nil,
            authenticatedOwnerAccountID: nil
        ))
    }

    /// An authenticated principal facing an unowned row is a mismatch, not a match — otherwise an
    /// unowned row would be a universal skeleton key under strict tenancy.
    @Test("unowned conversation rejects an authenticated principal")
    func unownedButAuthenticated() {
        #expect(!ConversationOwnerResolution.isOwner(
            conversationOwnerAccountID: nil,
            authenticatedOwnerAccountID: UUID()
        ))
    }

    @Test("nil conversation resolves through the optional overload identically")
    func nilConversationOverload() {
        #expect(ConversationOwnerResolution.isOwner(
            conversation: nil,
            authenticatedOwnerAccountID: nil
        ))
        #expect(!ConversationOwnerResolution.isOwner(
            conversation: nil,
            authenticatedOwnerAccountID: UUID()
        ))
    }
}
