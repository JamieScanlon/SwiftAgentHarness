import Foundation
import Logging

public struct ModelPoolBudgetConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var maxUSDPerCall: Double?
    public var maxUSDPerConversation: Double?
    public var maxUSDGlobal: Double?
    public var maxUSDPerAccount: Double?
    public var denyWhenUnknownProjectedCost: Bool

    public static let safeDefaults = ModelPoolBudgetConfiguration(
        enabled: true,
        maxUSDPerCall: 1.0,
        maxUSDPerConversation: 10.0,
        maxUSDGlobal: 100.0,
        maxUSDPerAccount: nil,
        denyWhenUnknownProjectedCost: true
    )

    public init(
        enabled: Bool,
        maxUSDPerCall: Double?,
        maxUSDPerConversation: Double?,
        maxUSDGlobal: Double?,
        maxUSDPerAccount: Double?,
        denyWhenUnknownProjectedCost: Bool
    ) {
        self.enabled = enabled
        self.maxUSDPerCall = maxUSDPerCall
        self.maxUSDPerConversation = maxUSDPerConversation
        self.maxUSDGlobal = maxUSDGlobal
        self.maxUSDPerAccount = maxUSDPerAccount
        self.denyWhenUnknownProjectedCost = denyWhenUnknownProjectedCost
    }

    public static func loadFromPromptConfigBundle(logger: Logger? = nil) -> ModelPoolBudgetConfiguration {
        guard let data = PromptConfigBundleResource.data() else {
            logger?.warning("PromptConfig.json not found; model pool budget safe defaults")
            return .safeDefaults
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["settings"] as? [String: Any] else {
            return .safeDefaults
        }
        return configuration(fromSettingsJSON: settings)
    }

    internal static func configuration(fromSettingsJSON settings: [String: Any]) -> ModelPoolBudgetConfiguration {
        guard let raw = settings["modelPoolBudget"] as? [String: Any] else {
            return .safeDefaults
        }
        let enabled = parseBool(raw["enabled"]) ?? true
        let maxUSDPerCall = parseDouble(raw["maxUSDPerCall"]) ?? safeDefaults.maxUSDPerCall
        let maxUSDPerConversation = parseDouble(raw["maxUSDPerConversation"]) ?? safeDefaults.maxUSDPerConversation
        let maxUSDGlobal = parseDouble(raw["maxUSDGlobal"]) ?? safeDefaults.maxUSDGlobal
        let maxUSDPerAccount = parseDouble(raw["maxUSDPerAccount"])
        let denyWhenUnknown = parseBool(raw["denyWhenUnknownProjectedCost"]) ?? safeDefaults.denyWhenUnknownProjectedCost
        return ModelPoolBudgetConfiguration(
            enabled: enabled,
            maxUSDPerCall: maxUSDPerCall,
            maxUSDPerConversation: maxUSDPerConversation,
            maxUSDGlobal: maxUSDGlobal,
            maxUSDPerAccount: maxUSDPerAccount,
            denyWhenUnknownProjectedCost: denyWhenUnknown
        )
    }

    public func applyingOverrides(serverConfig: ServerConfig) -> ModelPoolBudgetConfiguration {
        var resolved = self
        if let override = serverConfig.modelPoolBudgetEnabledOverride {
            resolved.enabled = override
        }
        if let override = serverConfig.modelPoolMaxUSDPerCallOverride {
            resolved.maxUSDPerCall = override
        }
        if let override = serverConfig.modelPoolMaxUSDPerConversationOverride {
            resolved.maxUSDPerConversation = override
        }
        if let override = serverConfig.modelPoolMaxUSDGlobalOverride {
            resolved.maxUSDGlobal = override
        }
        if let override = serverConfig.modelPoolMaxUSDPerAccountOverride {
            resolved.maxUSDPerAccount = override
        }
        if let override = serverConfig.modelPoolDenyWhenUnknownProjectedCostOverride {
            resolved.denyWhenUnknownProjectedCost = override
        }
        return resolved
    }

    public func applyingEnvironmentOverrides() -> ModelPoolBudgetConfiguration {
        let env = ProcessInfo.processInfo.environment
        if parseEnvBool(env["SAH_MODEL_POOL_BUDGET_DISABLED"]) == true {
            return ModelPoolBudgetConfiguration(
                enabled: false,
                maxUSDPerCall: maxUSDPerCall,
                maxUSDPerConversation: maxUSDPerConversation,
                maxUSDGlobal: maxUSDGlobal,
                maxUSDPerAccount: maxUSDPerAccount,
                denyWhenUnknownProjectedCost: denyWhenUnknownProjectedCost
            )
        }
        var resolved = self
        if let value = parseEnvDouble(env["SAH_MODEL_POOL_MAX_USD_PER_CALL"]) {
            resolved.maxUSDPerCall = value
        }
        if let value = parseEnvDouble(env["SAH_MODEL_POOL_MAX_USD_PER_CONVERSATION"]) {
            resolved.maxUSDPerConversation = value
        }
        if let value = parseEnvDouble(env["SAH_MODEL_POOL_MAX_USD_GLOBAL"]) {
            resolved.maxUSDGlobal = value
        }
        if let value = parseEnvDouble(env["SAH_MODEL_POOL_MAX_USD_PER_ACCOUNT"]) {
            resolved.maxUSDPerAccount = value
        }
        if let value = parseEnvBool(env["SAH_MODEL_POOL_DENY_WHEN_UNKNOWN_PROJECTED_COST"]) {
            resolved.denyWhenUnknownProjectedCost = value
        }
        return resolved
    }

    public func resolvedPolicy() -> BudgetPolicy {
        guard enabled else { return .disabled }
        let fallback: BudgetPolicy.ProjectedCostFallback = denyWhenUnknownProjectedCost
            ? .denyWhenUnknown
            : .allowWhenUnknown
        return .enabled(
            maxUSDPerCall: maxUSDPerCall,
            maxUSDPerConversation: maxUSDPerConversation,
            maxUSDGlobal: maxUSDGlobal,
            maxUSDPerAccount: maxUSDPerAccount,
            projectedCostFallback: fallback
        )
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? String, let parsed = Double(value) { return parsed }
        return nil
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private func parseEnvDouble(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func parseEnvBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }
}
