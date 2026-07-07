import Foundation
import Logging
import SwiftAgentKit

/// Optional `agentHarness` block in **PromptConfig.json** .
public struct AgentHarnessConfiguration: Sendable, Equatable {
    /// When true, agent (build) mode uses stronger goal-directed wording in ``SystemPrompt``.
    public var strictAgentHarnessPrompts: Bool
    /// Max outer `updateConversation` rounds with ephemeral continuation; `Int.max` means no harness cap.
    public var maxTurnLoopContinuationRounds: Int
    /// Truncated `plan.md` bytes appended to continuation user messages (UTF-8).
    public var planExcerptMaxCharacters: Int
    /// When > 0, every Nth continuation uses a watchdog-style nudge instead of the default text.
    public var watchdogEveryNContinuations: Int
    /// Stop the build loop after this many consecutive assistant turns with no tool calls but non-trivial text.
    public var maxConsecutiveChattyAssistantTurns: Int
    /// Stop when the same tool fingerprint repeats this many times across recent assistant turns.
    public var repeatToolCallStreakThreshold: Int
    /// Max LLM invocations (including tool follow-ups) per `updateConversation` in agent build mode; `nil` is unlimited.
    public var maxAgenticStepsPerUpdate: Int?
    /// Forwarded in ``OrchestratorInvocationOptions`` for agent build turns (maps to provider `tool_choice` when supported).
    public var agentBuildToolInvocationPolicy: ToolInvocationPolicy
    /// When true and tools are available, reject assistant turns with no tool calls and retry (see SwiftAgentKit orchestrator).
    public var rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: Bool
    /// Correction retries when the above rejection is enabled (`0` disables retry and may surface an error).
    public var maxCorrectionRetries: Int
    /// When true, runtime uses `TurnLoop` (direct model stream + loop-owned tool dispatch).
    public var useAgentLoop: Bool
    /// Idle seconds before an unreferenced orchestrator pool entry is eligible for eviction.
    public var orchestratorPoolIdleTTLSeconds: Int
    /// Max resident orchestrator pool entries (VRAM cap for loaded models); pairs with idle TTL eviction.
    public var orchestratorPoolMaxEntries: Int
    /// Deprecated: no longer affects output policy. Kept for PromptConfig backward compatibility.
    public var legacyStreamedTextSurfaces: Set<String>

    public static let `default` = AgentHarnessConfiguration(
        strictAgentHarnessPrompts: true,
        maxTurnLoopContinuationRounds: Int.max,
        planExcerptMaxCharacters: 6_000,
        watchdogEveryNContinuations: 0,
        maxConsecutiveChattyAssistantTurns: 4,
        repeatToolCallStreakThreshold: 5,
        maxAgenticStepsPerUpdate: nil,
        agentBuildToolInvocationPolicy: .automatic,
        rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: false,
        maxCorrectionRetries: 0,
        useAgentLoop: true,
        orchestratorPoolIdleTTLSeconds: 300,
        orchestratorPoolMaxEntries: 4,
        legacyStreamedTextSurfaces: []
    )

    public init(
        strictAgentHarnessPrompts: Bool,
        maxTurnLoopContinuationRounds: Int,
        planExcerptMaxCharacters: Int,
        watchdogEveryNContinuations: Int,
        maxConsecutiveChattyAssistantTurns: Int,
        repeatToolCallStreakThreshold: Int,
        maxAgenticStepsPerUpdate: Int?,
        agentBuildToolInvocationPolicy: ToolInvocationPolicy,
        rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: Bool,
        maxCorrectionRetries: Int,
        useAgentLoop: Bool = true,
        orchestratorPoolIdleTTLSeconds: Int = 300,
        orchestratorPoolMaxEntries: Int = 4,
        legacyStreamedTextSurfaces: Set<String> = []
    ) {
        self.strictAgentHarnessPrompts = strictAgentHarnessPrompts
        self.maxTurnLoopContinuationRounds = maxTurnLoopContinuationRounds
        self.planExcerptMaxCharacters = planExcerptMaxCharacters
        self.watchdogEveryNContinuations = watchdogEveryNContinuations
        self.maxConsecutiveChattyAssistantTurns = maxConsecutiveChattyAssistantTurns
        self.repeatToolCallStreakThreshold = repeatToolCallStreakThreshold
        self.maxAgenticStepsPerUpdate = maxAgenticStepsPerUpdate
        self.agentBuildToolInvocationPolicy = agentBuildToolInvocationPolicy
        self.rejectAssistantTurnWithNoToolCallsWhenToolsAvailable = rejectAssistantTurnWithNoToolCallsWhenToolsAvailable
        self.maxCorrectionRetries = maxCorrectionRetries
        self.useAgentLoop = useAgentLoop
        self.orchestratorPoolIdleTTLSeconds = orchestratorPoolIdleTTLSeconds
        self.orchestratorPoolMaxEntries = orchestratorPoolMaxEntries
        self.legacyStreamedTextSurfaces = legacyStreamedTextSurfaces
    }

    /// Hard stop for consecutive “chatty” (non-tool, long-text) assistant messages.
    public var effectiveMaxConsecutiveChattyAssistantTurns: Int {
        maxConsecutiveChattyAssistantTurns
    }

    public static func loadFromPromptConfigBundle(logger: Logger? = nil) -> AgentHarnessConfiguration {
        guard let data = PromptConfigBundleResource.data() else {
            logger?.warning("PromptConfig.json not found; agent harness defaults")
            return .default
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let harness = json["agentHarness"] as? [String: Any]
        else {
            return .default
        }
        return configuration(fromAgentHarnessJSON: harness)
    }

    /// Parses the `agentHarness` object from **PromptConfig.json** (used by tests with synthetic dictionaries).
    internal static func configuration(fromAgentHarnessJSON harness: [String: Any]) -> AgentHarnessConfiguration {
        func bool(_ key: String, default def: Bool) -> Bool {
            if let v = harness[key] as? Bool { return v }
            return def
        }
        func int(_ key: String, default def: Int, min: Int = 1, max: Int = 10_000) -> Int {
            if let v = harness[key] as? Int {
                return Swift.min(max, Swift.max(min, v))
            }
            return def
        }
        func optionalPositiveInt(_ key: String, max: Int = 500) -> Int? {
            guard let v = harness[key] as? Int else { return nil }
            if v <= 0 { return nil }
            return Swift.min(max, Swift.max(1, v))
        }
        func toolPolicy(_ key: String, default def: ToolInvocationPolicy) -> ToolInvocationPolicy {
            switch harness[key] as? String {
            case "automatic": return .automatic
            case "required": return .required
            case "none": return .none
            default: return def
            }
        }
        func stringSet(_ key: String) -> Set<String> {
            guard let values = harness[key] as? [String] else { return [] }
            return Set(values.filter { !$0.isEmpty })
        }
        return AgentHarnessConfiguration(
            strictAgentHarnessPrompts: bool("strictAgentHarnessPrompts", default: true),
            maxTurnLoopContinuationRounds: int("maxTurnLoopContinuationRounds", default: Int.max, min: 1, max: 500),
            planExcerptMaxCharacters: int("planExcerptMaxCharacters", default: 6_000, min: 500, max: 50_000),
            watchdogEveryNContinuations: int("watchdogEveryNContinuations", default: 0, min: 0, max: 100),
            maxConsecutiveChattyAssistantTurns: int("maxConsecutiveChattyAssistantTurns", default: 4, min: 1, max: 50),
            repeatToolCallStreakThreshold: int("repeatToolCallStreakThreshold", default: 5, min: 2, max: 50),
            maxAgenticStepsPerUpdate: optionalPositiveInt("maxAgenticStepsPerUpdate"),
            agentBuildToolInvocationPolicy: toolPolicy("agentBuildToolInvocationPolicy", default: .automatic),
            rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: bool("rejectAssistantTurnWithNoToolCallsWhenToolsAvailable", default: false),
            maxCorrectionRetries: int("maxCorrectionRetries", default: 0, min: 0, max: 20),
            useAgentLoop: bool("useAgentLoop", default: true),
            orchestratorPoolIdleTTLSeconds: int("orchestratorPoolIdleTTLSeconds", default: 300, min: 30, max: 86_400),
            orchestratorPoolMaxEntries: int("orchestratorPoolMaxEntries", default: 4, min: 1, max: 64),
            legacyStreamedTextSurfaces: stringSet("legacyStreamedTextSurfaces")
        )
    }
}
