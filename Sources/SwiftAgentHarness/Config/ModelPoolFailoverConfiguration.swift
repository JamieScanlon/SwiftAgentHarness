import Foundation
import Logging

public struct ModelPoolFailoverConfiguration: Sendable, Equatable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitterFraction: Double
    public var rotationStrategy: AuthProfileRotationStrategy
    public var billingCooldown: TimeInterval
    public var rateLimitCooldown: TimeInterval

    public static let specDefaults = ModelPoolFailoverConfiguration(
        maxRetries: 2,
        baseDelay: 0.25,
        maxDelay: 5.0,
        jitterFraction: 0.25,
        rotationStrategy: .fillFirst,
        billingCooldown: 3600,
        rateLimitCooldown: 900
    )

    public init(
        maxRetries: Int,
        baseDelay: TimeInterval,
        maxDelay: TimeInterval,
        jitterFraction: Double,
        rotationStrategy: AuthProfileRotationStrategy = .fillFirst,
        billingCooldown: TimeInterval = 3600,
        rateLimitCooldown: TimeInterval = 900
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitterFraction = max(0, min(1, jitterFraction))
        self.rotationStrategy = rotationStrategy
        self.billingCooldown = billingCooldown
        self.rateLimitCooldown = rateLimitCooldown
    }

    public static func load(from document: PromptConfigDocument, logger: Logger? = nil) -> ModelPoolFailoverConfiguration {
        guard let settings = document.foundationObject(forKey: "settings") else {
            return .specDefaults
        }
        return configuration(fromSettingsJSON: settings)
    }

    @available(*, deprecated, message: "Pass HarnessConfigurationSet or load(from: PromptConfigDocument)")

    internal static func configuration(fromSettingsJSON settings: [String: Any]) -> ModelPoolFailoverConfiguration {
        guard let raw = settings["modelPoolFailover"] as? [String: Any] else {
            return .specDefaults
        }
        let maxRetries = parseInt(raw["maxRetries"]) ?? specDefaults.maxRetries
        let baseDelay = parseDouble(raw["baseDelaySeconds"]) ?? specDefaults.baseDelay
        let maxDelay = parseDouble(raw["maxDelaySeconds"]) ?? specDefaults.maxDelay
        let jitter = parseDouble(raw["jitterFraction"]) ?? specDefaults.jitterFraction
        let rotationStrategy = parseRotationStrategy(raw["rotationStrategy"]) ?? specDefaults.rotationStrategy
        let billingCooldown = parseDouble(raw["billingCooldownSeconds"]) ?? specDefaults.billingCooldown
        let rateLimitCooldown = parseDouble(raw["rateLimitCooldownSeconds"]) ?? specDefaults.rateLimitCooldown
        return ModelPoolFailoverConfiguration(
            maxRetries: maxRetries,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            jitterFraction: jitter,
            rotationStrategy: rotationStrategy,
            billingCooldown: billingCooldown,
            rateLimitCooldown: rateLimitCooldown
        )
    }

    public func applyingOverrides(serverConfig: ServerConfig) -> ModelPoolFailoverConfiguration {
        var resolved = self
        if let override = serverConfig.modelPoolFailoverMaxRetriesOverride {
            resolved.maxRetries = override
        }
        if let override = serverConfig.modelPoolFailoverBaseDelayOverride {
            resolved.baseDelay = override
        }
        if let override = serverConfig.modelPoolFailoverMaxDelayOverride {
            resolved.maxDelay = override
        }
        return resolved
    }

    public func resolvedPolicy() -> FailoverPolicy {
        FailoverPolicy(
            maxRetries: maxRetries,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            jitterFraction: jitterFraction,
            rotationStrategy: rotationStrategy,
            billingCooldown: billingCooldown,
            rateLimitCooldown: rateLimitCooldown
        )
    }

    private static func parseRotationStrategy(_ raw: Any?) -> AuthProfileRotationStrategy? {
        guard let value = raw as? String else { return nil }
        return AuthProfileRotationStrategy(rawValue: value)
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String, let parsed = Int(value) { return parsed }
        return nil
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? String, let parsed = Double(value) { return parsed }
        return nil
    }
}
