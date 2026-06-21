import Foundation
import Logging

public struct ModelPoolFailoverConfiguration: Sendable, Equatable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitterFraction: Double

    public static let specDefaults = ModelPoolFailoverConfiguration(
        maxRetries: 2,
        baseDelay: 0.25,
        maxDelay: 5.0,
        jitterFraction: 0.25
    )

    public init(
        maxRetries: Int,
        baseDelay: TimeInterval,
        maxDelay: TimeInterval,
        jitterFraction: Double
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitterFraction = max(0, min(1, jitterFraction))
    }

    public static func loadFromPromptConfigBundle(logger: Logger? = nil) -> ModelPoolFailoverConfiguration {
        guard let url = Bundle.module.url(forResource: "PromptConfig", withExtension: "json") else {
            return .specDefaults
        }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["settings"] as? [String: Any] else {
            return .specDefaults
        }
        return configuration(fromSettingsJSON: settings)
    }

    internal static func configuration(fromSettingsJSON settings: [String: Any]) -> ModelPoolFailoverConfiguration {
        guard let raw = settings["modelPoolFailover"] as? [String: Any] else {
            return .specDefaults
        }
        let maxRetries = parseInt(raw["maxRetries"]) ?? specDefaults.maxRetries
        let baseDelay = parseDouble(raw["baseDelaySeconds"]) ?? specDefaults.baseDelay
        let maxDelay = parseDouble(raw["maxDelaySeconds"]) ?? specDefaults.maxDelay
        let jitter = parseDouble(raw["jitterFraction"]) ?? specDefaults.jitterFraction
        return ModelPoolFailoverConfiguration(
            maxRetries: maxRetries,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            jitterFraction: jitter
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
            jitterFraction: jitterFraction
        )
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
