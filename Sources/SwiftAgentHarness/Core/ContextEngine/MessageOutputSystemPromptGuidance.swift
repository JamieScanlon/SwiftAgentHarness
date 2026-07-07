import Foundation

enum MessageOutputSystemPromptGuidance {
    static let channelOutputVerb = """
    Output contract: write your reply as normal text. Use the `message` tool only for structured output — \
    buttons, selects, titled/toned blocks — or when you need an explicit delivery action (media). \
    Do not wrap ordinary prose in the tool. Approvals are delivered natively or via `/approve`; \
    do not narrate text approval prompts when native controls are available.
    """

    static let interactiveOutputVerb = """
    Output contract: write your reply as normal text. Use the `message` tool only for structured output — \
    buttons, selects, titled/toned blocks — or when you need an explicit delivery action (media). \
    Do not wrap ordinary prose in the tool. Use native approval UI when available; \
    do not narrate approval prompts as plain assistant prose.
    """

    static func mergedReminder(existing: String?, policy: MessageOutputPolicy) -> String? {
        guard policy == .structuredPreferred else { return existing }
        let guidance = interactiveOutputVerb
        guard let existing, !existing.isEmpty else { return guidance }
        if existing.contains("Output contract:") { return existing }
        return existing + "\n\n" + guidance
    }
}
