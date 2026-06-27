import Foundation

enum MessageOutputSystemPromptGuidance {
    static let channelOutputVerb = """
    Output contract: emit all user-visible replies using the `message` tool with portable presentation blocks. \
    Do not rely on free-form assistant text for user-visible content on messaging channels. \
    Approvals are delivered natively or via `/approve`; do not narrate text approval prompts when native controls are available.
    """

    static let interactiveOutputVerb = """
    Output contract: emit all user-visible replies using the `message` tool with portable presentation blocks. \
    Do not rely on free-form assistant text for user-visible content in this interface. \
    Use native approval UI when available; do not narrate approval prompts as plain assistant prose.
    """

    static func mergedReminder(existing: String?, policy: MessageOutputPolicy) -> String? {
        guard policy == .messageToolOnly else { return existing }
        let guidance = interactiveOutputVerb
        guard let existing, !existing.isEmpty else { return guidance }
        if existing.contains("Output contract:") { return existing }
        return existing + "\n\n" + guidance
    }
}
