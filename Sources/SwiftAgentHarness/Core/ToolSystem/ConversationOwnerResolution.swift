import Foundation

/// Single source of truth for "is this principal the conversation's owner".
///
/// The slash-command boundary and the tool-policy path both need this verdict. Today they would be
/// two copies of the same three lines, which is how they drift apart.
///
/// The principal is an **explicit parameter** rather than a read of ``APISessionContext``'s
/// task-locals. Those are bound only by `ClientSessionMiddleware` (Vapor request) and `APILayer`
/// (WS control message); a channel-dispatched turn runs outside that task tree, so a task-local
/// read answers `nil` for it — and the verdict then depends on which task tree the caller happens
/// to be on rather than on who is speaking. (Which way that lands is not uniform: for an *owned*
/// conversation a `nil` principal yields `false`, the restrictive answer; for an unowned one it
/// yields `true`.) Passing the principal in removes the dependency either way.
enum ConversationOwnerResolution {
    /// - Returns: `true` when the principal owns the conversation, `false` when it demonstrably does
    ///   not. This is a two-valued question: "no sender concept at all" is modeled by the caller,
    ///   above this function, not by a third case here.
    static func isOwner(
        conversationOwnerAccountID: UUID?,
        authenticatedOwnerAccountID: UUID?
    ) -> Bool {
        guard let conversationOwnerAccountID else {
            // An unowned conversation is owner-operated exactly when nobody is authenticated
            // against it. An authenticated principal facing an unowned row is a mismatch, not
            // a match.
            return authenticatedOwnerAccountID == nil
        }
        guard let authenticatedOwnerAccountID else { return false }
        return conversationOwnerAccountID == authenticatedOwnerAccountID
    }

    static func isOwner(
        conversation: ModelConversation?,
        authenticatedOwnerAccountID: UUID?
    ) -> Bool {
        isOwner(
            conversationOwnerAccountID: conversation?.ownerAccountID,
            authenticatedOwnerAccountID: authenticatedOwnerAccountID
        )
    }
}
