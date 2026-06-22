import Foundation
import Logging

public struct MemoryConfiguration: Sendable, Equatable {
    var enabled: Bool
    var managedInstructionsPath: String?
    var extractionEnabled: Bool
    var extractionThrottleTurns: Int
    var activeMemoryEnabled: Bool
    var activeMemoryTimeoutMs: Int
    var activeMemoryMaxSummaryChars: Int
    var teamMemoryEnabled: Bool
    var dreamingCron: String
    var dreamingMinScore: Double
    var recallSelectorModel: String
    var recallSelectorOllamaServerURL: URL
    var activeMemoryModel: String
    var activeMemoryOllamaServerURL: URL
    var extractionRecentMessageCount: Int
    var preCompactionFlushEnabled: Bool
    var preCompactionFlushTimeoutMs: Int
    var preCompactionFlushMaxIterations: Int
    var activeMemoryStandingEnabled: Bool
    var activeMemoryStandingTTLMs: Int
    var activeMemoryStandingBudgetMs: Int
    var activeMemorySituationalEnabled: Bool
    var activeMemorySituationalTimeoutMs: Int
    var activeMemorySituationalTTLMs: Int

    static let `default` = MemoryConfiguration(
        enabled: true,
        managedInstructionsPath: nil,
        extractionEnabled: true,
        extractionThrottleTurns: 1,
        activeMemoryEnabled: true,
        activeMemoryTimeoutMs: 2_500,
        activeMemoryMaxSummaryChars: 4_000,
        teamMemoryEnabled: true,
        dreamingCron: "0 3 * * *",
        dreamingMinScore: 0.55,
        recallSelectorModel: "llama3.2:3b",
        recallSelectorOllamaServerURL: URL(string: "http://127.0.0.1:11434")!,
        activeMemoryModel: "llama3.2:3b",
        activeMemoryOllamaServerURL: URL(string: "http://127.0.0.1:11434")!,
        extractionRecentMessageCount: 20,
        preCompactionFlushEnabled: true,
        preCompactionFlushTimeoutMs: 30_000,
        preCompactionFlushMaxIterations: 2,
        activeMemoryStandingEnabled: true,
        activeMemoryStandingTTLMs: 3_600_000,
        activeMemoryStandingBudgetMs: 15_000,
        activeMemorySituationalEnabled: true,
        activeMemorySituationalTimeoutMs: 2_500,
        activeMemorySituationalTTLMs: 60_000
    )
}

public enum MemoryConfigurationLoader {
    public static func loadFromPromptConfigBundle(logger: Logger? = nil) -> MemoryConfiguration {
        guard let url = PromptConfigBundleResource.url(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let memory = json["memory"] as? [String: Any] else {
            return .default
        }
        var config = MemoryConfiguration.default
        if let enabled = memory["enabled"] as? Bool { config.enabled = enabled }
        if let path = memory["managedInstructionsPath"] as? String { config.managedInstructionsPath = path.nilIfEmpty }
        if let v = memory["extractionEnabled"] as? Bool { config.extractionEnabled = v }
        if let v = memory["extractionThrottleTurns"] as? Int { config.extractionThrottleTurns = max(1, v) }
        if let v = memory["activeMemoryEnabled"] as? Bool { config.activeMemoryEnabled = v }
        if let v = memory["activeMemoryTimeoutMs"] as? Int { config.activeMemoryTimeoutMs = max(1, v) }
        if let v = memory["activeMemoryMaxSummaryChars"] as? Int { config.activeMemoryMaxSummaryChars = max(256, v) }
        if let v = memory["teamMemoryEnabled"] as? Bool { config.teamMemoryEnabled = v }
        if let v = memory["dreamingCron"] as? String { config.dreamingCron = v }
        if let v = memory["dreamingMinScore"] as? Double { config.dreamingMinScore = v }
        if let v = memory["recallSelectorModel"] as? String, !v.isEmpty { config.recallSelectorModel = v }
        if let urlString = memory["recallSelectorOllamaServerURL"] as? String,
           let url = URL(string: urlString) {
            config.recallSelectorOllamaServerURL = url
        }
        if let v = memory["activeMemoryModel"] as? String, !v.isEmpty { config.activeMemoryModel = v }
        if let urlString = memory["activeMemoryOllamaServerURL"] as? String,
           let url = URL(string: urlString) {
            config.activeMemoryOllamaServerURL = url
        }
        if let v = memory["extractionRecentMessageCount"] as? Int {
            config.extractionRecentMessageCount = max(1, v)
        }
        if let v = memory["preCompactionFlushEnabled"] as? Bool { config.preCompactionFlushEnabled = v }
        if let v = memory["preCompactionFlushTimeoutMs"] as? Int { config.preCompactionFlushTimeoutMs = max(1, v) }
        if let v = memory["preCompactionFlushMaxIterations"] as? Int { config.preCompactionFlushMaxIterations = max(1, v) }
        if let v = memory["activeMemoryStandingEnabled"] as? Bool { config.activeMemoryStandingEnabled = v }
        if let v = memory["activeMemoryStandingTTLMs"] as? Int { config.activeMemoryStandingTTLMs = max(1, v) }
        if let v = memory["activeMemoryStandingBudgetMs"] as? Int { config.activeMemoryStandingBudgetMs = max(1, v) }
        if let v = memory["activeMemorySituationalEnabled"] as? Bool { config.activeMemorySituationalEnabled = v }
        if let v = memory["activeMemorySituationalTTLMs"] as? Int { config.activeMemorySituationalTTLMs = max(1, v) }
        // Prefer explicit situational key; fall back to legacy activeMemoryTimeoutMs
        if let v = memory["activeMemorySituationalTimeoutMs"] as? Int {
            config.activeMemorySituationalTimeoutMs = max(1, v)
        } else {
            config.activeMemorySituationalTimeoutMs = config.activeMemoryTimeoutMs
        }
        return config
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
