import Foundation

/// Message body for a Send Message REST API call
struct ChatRequest: Codable {

    let conversationID: String?
    let message: String
    let imageNames: [String]
    let includeTools: Bool?
    let includeAgents: Bool?
    /// Optional optimistic-append guard: must match the harness-visible id of the current active transcript tail (`Message.id` from list messages).
    let expectedPreviousTailHarnessMessageID: UUID?
    /// Optional user-input trust (same JSON key and semantics as SwiftAgentKit ``Message`` / `inputTrust`).
    let inputTrust: String?
    /// Optional interactive surface provenance (trigger/channel hosts).
    let originSurface: String?
    /// Optional sender id for provenance.
    let originSenderID: String?
    /// Optional sender-scoped **self-restriction**: `true` asserts the human behind this request is
    /// *not* the conversation owner.
    ///
    /// Negative-only by design. This field is attacker-controllable like every other field in this
    /// body, so it may only ever *lower* the sender's privilege. The affirmative verdict is resolved
    /// server-side from the authenticated principal and is never read from the wire — otherwise any
    /// caller that can reach `/api` could assert ownership and walk through control-plane tool
    /// policy.
    let originSenderIsNonOwner: Bool?
}

