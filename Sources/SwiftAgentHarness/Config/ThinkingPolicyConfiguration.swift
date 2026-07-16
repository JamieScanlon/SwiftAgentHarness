import Foundation
import Logging

public struct ThinkingPolicyConfiguration: Sendable, Equatable {
    public var defaultThinkingConfig: ThinkingConfig
    public var thinkingBudgets: [ThinkingLevel: Int]

    public static let `default` = ThinkingPolicyConfiguration(
        defaultThinkingConfig: .disabled,
        thinkingBudgets: [:]
    )

    public init(
        defaultThinkingConfig: ThinkingConfig,
        thinkingBudgets: [ThinkingLevel: Int]
    ) {
        self.defaultThinkingConfig = defaultThinkingConfig
        self.thinkingBudgets = thinkingBudgets
    }

    public static func load(from document: PromptConfigDocument, logger: Logger? = nil) -> ThinkingPolicyConfiguration {
        guard let settings = document.foundationObject(forKey: "settings") else {
            return .default
        }
        return configuration(fromSettingsJSON: settings)
    }

    @available(*, deprecated, message: "Pass HarnessConfigurationSet or load(from: PromptConfigDocument)")

    internal static func configuration(fromSettingsJSON settings: [String: Any]) -> ThinkingPolicyConfiguration {
        let defaultThinkingConfig = parseThinkingConfig(settings["defaultThinkingConfig"]) ?? .disabled
        var thinkingBudgets: [ThinkingLevel: Int] = [:]
        if let budgets = settings["thinkingBudgets"] as? [String: Any] {
            for (key, value) in budgets {
                guard let level = ThinkingLevel(rawValue: key) else { continue }
                if let direct = value as? Int {
                    thinkingBudgets[level] = max(0, direct)
                } else if let decimal = value as? Double {
                    thinkingBudgets[level] = max(0, Int(decimal))
                }
            }
        }
        return ThinkingPolicyConfiguration(
            defaultThinkingConfig: defaultThinkingConfig,
            thinkingBudgets: thinkingBudgets
        )
    }

    private static func parseThinkingConfig(_ raw: Any?) -> ThinkingConfig? {
        if let value = raw as? String {
            switch value {
            case "disabled":
                return .disabled
            case "adaptive":
                return .adaptive
            default:
                return nil
            }
        }
        guard let object = raw as? [String: Any],
              let levelRaw = object["level"] as? String,
              let level = ThinkingLevel(rawValue: levelRaw) else {
            return nil
        }
        let budgetTokens: Int?
        if let direct = object["budgetTokens"] as? Int {
            budgetTokens = direct
        } else if let decimal = object["budgetTokens"] as? Double {
            budgetTokens = Int(decimal)
        } else {
            budgetTokens = nil
        }
        return .level(level, budgetTokens: budgetTokens)
    }
}
