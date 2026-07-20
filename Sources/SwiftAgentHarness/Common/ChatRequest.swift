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
}

