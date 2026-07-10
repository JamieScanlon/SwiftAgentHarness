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
    /// Deploy-time opt-in for autonomous dreaming sweeps (default off). Soft `/dreaming` toggle applies after this is on.
    var dreamingEnabled: Bool
    var dreamingCron: String
    var dreamingMinScore: Double
    var dreamingMinRecallCount: Int
    var dreamingMinUniqueQueries: Int
    public var recallSelectorModel: String
    public var recallSelectorOllamaServerURL: URL
    /// Optional Model Pool pin (slug or UUID). When nil, active memory resolves via pool query + session last resort.
    var activeMemoryModelRef: String?
    /// Legacy Ollama endpoint still used by ``ModelPoolMemoryLLMRecallSelector`` until that path migrates.
    var activeMemoryOllamaServerURL: URL
    /// When false (default), pool candidates must not exceed the parent session's provider trust tier.
    var activeMemoryAllowCrossProviderTrust: Bool
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
    /// Situational lane conversation window (default `recent` for follow-up pronouns).
    var activeMemoryQueryMode: ActiveMemoryQueryMode
    /// Situational recall eagerness (default `balanced`).
    var activeMemoryPromptStyle: ActiveMemoryPromptStyle
    var activeMemoryRecentUserTurns: Int
    var activeMemoryRecentAssistantTurns: Int
    var activeMemoryRecentUserChars: Int
    var activeMemoryRecentAssistantChars: Int
    /// Structured `active-memory: start|done` debug logs (default on for the tuning loop).
    var activeMemoryLogging: Bool

    public static let `default` = MemoryConfiguration(
        enabled: true,
        managedInstructionsPath: nil,
        extractionEnabled: true,
        extractionThrottleTurns: 1,
        activeMemoryEnabled: true,
        activeMemoryTimeoutMs: 2_500,
        activeMemoryMaxSummaryChars: 220,
        teamMemoryEnabled: true,
        dreamingEnabled: false,
        dreamingCron: "0 3 * * *",
        dreamingMinScore: 0.75,
        dreamingMinRecallCount: 2,
        dreamingMinUniqueQueries: 2,
        recallSelectorModel: "llama3.2:3b",
        recallSelectorOllamaServerURL: URL(string: "http://127.0.0.1:11434")!,
        activeMemoryModelRef: nil,
        activeMemoryOllamaServerURL: URL(string: "http://127.0.0.1:11434")!,
        activeMemoryAllowCrossProviderTrust: false,
        extractionRecentMessageCount: 20,
        preCompactionFlushEnabled: true,
        preCompactionFlushTimeoutMs: 30_000,
        preCompactionFlushMaxIterations: 2,
        activeMemoryStandingEnabled: true,
        activeMemoryStandingTTLMs: 3_600_000,
        activeMemoryStandingBudgetMs: 15_000,
        activeMemorySituationalEnabled: true,
        activeMemorySituationalTimeoutMs: 2_500,
        activeMemorySituationalTTLMs: 60_000,
        activeMemoryQueryMode: .recent,
        activeMemoryPromptStyle: .balanced,
        activeMemoryRecentUserTurns: 2,
        activeMemoryRecentAssistantTurns: 1,
        activeMemoryRecentUserChars: 220,
        activeMemoryRecentAssistantChars: 180,
        activeMemoryLogging: true
    )
}

public enum MemoryConfigurationLoader {
    public static func loadFromPromptConfigBundle(logger: Logger? = nil) -> MemoryConfiguration {
        guard let data = PromptConfigBundleResource.data(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let memory = json["memory"] as? [String: Any] else {
            return .default
        }
        return load(fromMemoryObject: memory)
    }

    /// Applies a PromptConfig `memory` object onto defaults (testable without the bundle).
    public static func load(fromMemoryObject memory: [String: Any]) -> MemoryConfiguration {
        var config = MemoryConfiguration.default
        if let enabled = memory["enabled"] as? Bool { config.enabled = enabled }
        if let path = memory["managedInstructionsPath"] as? String { config.managedInstructionsPath = path.nilIfEmpty }
        if let v = memory["extractionEnabled"] as? Bool { config.extractionEnabled = v }
        if let v = memory["extractionThrottleTurns"] as? Int { config.extractionThrottleTurns = max(1, v) }
        if let v = memory["activeMemoryEnabled"] as? Bool { config.activeMemoryEnabled = v }
        if let v = memory["activeMemoryTimeoutMs"] as? Int { config.activeMemoryTimeoutMs = max(1, v) }
        if let v = memory["activeMemoryMaxSummaryChars"] as? Int {
            config.activeMemoryMaxSummaryChars = min(1_000, max(40, v))
        }
        if let v = memory["teamMemoryEnabled"] as? Bool { config.teamMemoryEnabled = v }
        if let v = memory["dreamingEnabled"] as? Bool { config.dreamingEnabled = v }
        if let v = memory["dreamingCron"] as? String { config.dreamingCron = v }
        if let v = memory["dreamingMinScore"] as? Double { config.dreamingMinScore = v }
        if let v = memory["dreamingMinRecallCount"] as? Int { config.dreamingMinRecallCount = max(1, v) }
        if let v = memory["dreamingMinUniqueQueries"] as? Int { config.dreamingMinUniqueQueries = max(1, v) }
        if let v = memory["recallSelectorModel"] as? String, !v.isEmpty { config.recallSelectorModel = v }
        if let urlString = memory["recallSelectorOllamaServerURL"] as? String,
           let url = URL(string: urlString) {
            config.recallSelectorOllamaServerURL = url
        }
        if let v = memory["activeMemoryModelRef"] as? String, !v.isEmpty {
            config.activeMemoryModelRef = v
        } else if let legacy = memory["activeMemoryModel"] as? String, !legacy.isEmpty {
            // Legacy key: treat as an optional pool pin (slug), not a mandatory Ollama model name.
            config.activeMemoryModelRef = legacy
        }
        if let urlString = memory["activeMemoryOllamaServerURL"] as? String,
           let url = URL(string: urlString) {
            config.activeMemoryOllamaServerURL = url
        }
        if let v = memory["activeMemoryAllowCrossProviderTrust"] as? Bool {
            config.activeMemoryAllowCrossProviderTrust = v
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
        if let raw = memory["activeMemoryQueryMode"] as? String,
           let mode = ActiveMemoryQueryMode(rawValue: raw) {
            config.activeMemoryQueryMode = mode
        }
        if let raw = memory["activeMemoryPromptStyle"] as? String,
           let style = ActiveMemoryPromptStyle(rawValue: raw) {
            config.activeMemoryPromptStyle = style
        }
        if let v = memory["activeMemoryRecentUserTurns"] as? Int {
            config.activeMemoryRecentUserTurns = min(4, max(0, v))
        }
        if let v = memory["activeMemoryRecentAssistantTurns"] as? Int {
            config.activeMemoryRecentAssistantTurns = min(3, max(0, v))
        }
        if let v = memory["activeMemoryRecentUserChars"] as? Int {
            config.activeMemoryRecentUserChars = min(1_000, max(40, v))
        }
        if let v = memory["activeMemoryRecentAssistantChars"] as? Int {
            config.activeMemoryRecentAssistantChars = min(1_000, max(40, v))
        }
        if let v = memory["activeMemoryLogging"] as? Bool {
            config.activeMemoryLogging = v
        }
        return config
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
