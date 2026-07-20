import Foundation
import Logging

public struct ModelPoolProviderPreferenceConfiguration: Sendable, Equatable {
    public var order: [ProviderID]

    public static let specDefaults = ModelPoolProviderPreferenceConfiguration(
        order: ["anthropic", "openai", "ollama", "lmstudio", "openrouter"]
    )

    public init(order: [ProviderID]) {
        self.order = order
    }

    public static func load(from document: PromptConfigDocument, logger: Logger? = nil) -> ModelPoolProviderPreferenceConfiguration {
        guard let settings = document.foundationObject(forKey: "settings") else {
            return .specDefaults
        }
        return configuration(fromSettingsJSON: settings)
    }

    @available(*, deprecated, message: "Pass HarnessConfigurationSet or load(from: PromptConfigDocument)")

    internal static func configuration(fromSettingsJSON settings: [String: Any]) -> ModelPoolProviderPreferenceConfiguration {
        guard let raw = settings["modelPoolProviderPreference"] as? [String: Any],
              let orderRaw = raw["order"] as? [String],
              !orderRaw.isEmpty else {
            return .specDefaults
        }
        return ModelPoolProviderPreferenceConfiguration(order: orderRaw)
    }

    public func applyingOverrides(serverConfig: ServerConfig) -> ModelPoolProviderPreferenceConfiguration {
        guard let override = serverConfig.modelPoolProviderPreferenceOrderOverride, !override.isEmpty else {
            return self
        }
        return ModelPoolProviderPreferenceConfiguration(order: override)
    }

    public func resolvedOrder() -> [ProviderID] {
        order
    }

    func preferenceIndex(for providerId: ProviderID) -> Int {
        if let index = order.firstIndex(of: providerId) {
            return index
        }
        return order.count + 1
    }
}
