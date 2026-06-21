import Foundation

enum ThinkingCallContext: Sendable, Equatable {
    case foreground
    case subAgent
    case background(purpose: String?)
}

enum ThinkingConfigResolver {
    static func resolve(
        settingsDefault: ThinkingConfig,
        modeThinkingConfig: ThinkingConfig?,
        conversationThinkingConfig: ThinkingConfig?,
        thinkingBudgets: [ThinkingLevel: Int],
        callContext: ThinkingCallContext
    ) -> ThinkingConfig {
        if isSuppressedContext(callContext) {
            return .disabled
        }

        if case .subAgent = callContext, conversationThinkingConfig == nil {
            return .disabled
        }

        var resolved = settingsDefault
        if let modeThinkingConfig {
            resolved = modeThinkingConfig
        }
        if let conversationThinkingConfig {
            resolved = conversationThinkingConfig
        }

        switch resolved {
        case .level(let level, .none):
            return .level(level, budgetTokens: thinkingBudgets[level])
        default:
            return resolved
        }
    }

    private static func isSuppressedContext(_ context: ThinkingCallContext) -> Bool {
        guard case .background(let purpose) = context else {
            return false
        }
        guard let purpose = purpose?.lowercased(), !purpose.isEmpty else {
            return true
        }
        if purpose.contains("classifier") || purpose.contains("permission") || purpose.contains("background") {
            return true
        }
        if purpose.hasPrefix("transform.") {
            return true
        }
        return false
    }
}
