import Foundation

// MARK: - Template-shaped slices (modes.md inner-ring consumption)

/// Tool-system slice after ``extends`` flattening.
public struct ModeProfileToolsSlice: Sendable, Equatable {
    /// When nil, the profile adds no extra allow constraint for tools.
    public var allow: [String]?
    /// Unioned deny names from the inheritance chain (evaluated before allow intersection).
    public var deny: [String]
    /// Optional mode-level approval posture (composed with PromptConfig tool tags).
    public var approvalPolicy: ModeProfileToolApprovalPolicy?

    public init(
        allow: [String]?,
        deny: [String],
        approvalPolicy: ModeProfileToolApprovalPolicy? = nil
    ) {
        self.allow = allow
        self.deny = deny
        self.approvalPolicy = approvalPolicy
    }

    public static let neutral = ModeProfileToolsSlice(allow: nil, deny: [], approvalPolicy: nil)
}

/// Agent-skills slice after ``extends`` flattening (same allow/deny semantics as ``ModeProfileToolsSlice``).
public struct ModeProfileSkillsSlice: Sendable, Equatable {
    /// When nil, no profile allow constraint for skills.
    public var allow: [String]?
    /// Unioned deny names from the inheritance chain (evaluated before allow).
    public var deny: [String]

    public init(allow: [String]? = nil, deny: [String] = []) {
        self.allow = allow
        self.deny = deny
    }

    public static let neutral = ModeProfileSkillsSlice(allow: nil, deny: [])

    public func isSkillDenied(name: String) -> Bool {
        Self.evalDenylist(deny, skillName: name)
    }

    public func isSkillAllowed(name: String, context: ModePolicyContext) -> Bool {
        if context.resolvedProfile.context.includeSkills == false {
            return false
        }
        if isSkillDenied(name: name) {
            return false
        }
        return Self.profileSkillsSliceAllows(allow, skillName: name)
    }

    /// Checks conversation-level routing skill policy (harness `routing.skillsOverride`).
    public static func isSkillAllowedByRoutingPolicy(name: String, conversation: ModelConversation) -> Bool {
        guard let routingPrefs = conversation.routingPrefs,
              let policy = routingPrefs.explicitToolPolicy else {
            return true
        }
        switch policy {
        case .allowlist(_, let skills):
            if skills.isEmpty { return true }
            if skills.contains("*") { return true }
            return skills.contains(name)
        case .denylist(_, let skills):
            if skills.isEmpty { return true }
            if skills.contains("*") { return false }
            return !skills.contains(name)
        }
    }

    private static func profileSkillsSliceAllows(_ allow: [String]?, skillName: String) -> Bool {
        guard let allow else { return true }
        return evalAllowlist(allow, skillName: skillName)
    }

    private static func evalAllowlist(_ list: [String], skillName: String) -> Bool {
        if list.isEmpty { return false }
        if list.contains("*") { return true }
        return list.contains(skillName)
    }

    private static func evalDenylist(_ list: [String], skillName: String) -> Bool {
        if list.isEmpty { return false }
        if list.contains("*") { return true }
        return list.contains(skillName)
    }
}

public enum ModeProfileToolApprovalPolicy: String, Sendable {
    case never
    case sideEffects = "side-effects"
    case all
}

/// Context-engine slice (sectioned assembly / directives — see MODES_PARITY wiring notes).
public struct ModeProfileContextSlice: Sendable, Equatable {
    public var compactionLevel: String?
    public var modeDirective: String?
    public var sectionOverrides: [String: String]
    public var suppressSections: [String]
    public var memoryInjection: String?
    /// When non-nil, overrides PromptConfig `options.includeAgentSkills` for CE / orchestration policy input.
    public var includeSkills: Bool?
    /// Reserved for future sectioned tool-guidance toggles (included in fingerprints today).
    public var includeToolGuidance: Bool?

    public init(
        compactionLevel: String? = nil,
        modeDirective: String? = nil,
        sectionOverrides: [String: String] = [:],
        suppressSections: [String] = [],
        memoryInjection: String? = nil,
        includeSkills: Bool? = nil,
        includeToolGuidance: Bool? = nil
    ) {
        self.compactionLevel = compactionLevel
        self.modeDirective = modeDirective
        self.sectionOverrides = sectionOverrides
        self.suppressSections = suppressSections
        self.memoryInjection = memoryInjection
        self.includeSkills = includeSkills
        self.includeToolGuidance = includeToolGuidance
    }

    public static let neutral = ModeProfileContextSlice()
}

public enum ModeProfileTerminationPolicy: String, Sendable {
    case bareMessage = "bare-message"
    case terminalTool = "terminal-tool"
}

public enum ModeProfileTerminationRecoveryStrategy: String, Sendable {
    /// Force `tool_choice` at the provider when the model supports it; auto-degrades to
    /// behavioral recovery for models that do not advertise the `.required` mode.
    case forcedToolChoice = "forced-tool-choice"
    /// Never force `tool_choice`; rely on escalating reminders and `think` injection.
    case behavioralFallback = "behavioral-fallback"
}

public enum ModeProfileTerminationRecoveryReminder: String, Sendable {
    case off
    case escalating
}

public struct ModeProfileTerminationRecoverySlice: Sendable, Equatable {
    public var strategy: ModeProfileTerminationRecoveryStrategy
    public var rollbackStalledTurn: Bool
    public var maxAttempts: Int
    public var reminder: ModeProfileTerminationRecoveryReminder
    /// Behavioral recovery only: after this many consecutive stalls, the runtime injects a
    /// deterministic `think` tool call to break a text-only loop on models that cannot be forced.
    public var behavioralInjectAfterStalls: Int
    /// Behavioral recovery only: temperature applied to the next model call while recovering, to
    /// nudge a stalling model toward a clean tool call. `nil` keeps the orchestrator's temperature.
    public var behavioralRecoveryTemperature: Double?

    public init(
        strategy: ModeProfileTerminationRecoveryStrategy = .forcedToolChoice,
        rollbackStalledTurn: Bool = true,
        maxAttempts: Int = 2,
        reminder: ModeProfileTerminationRecoveryReminder = .escalating,
        behavioralInjectAfterStalls: Int = 2,
        behavioralRecoveryTemperature: Double? = nil
    ) {
        self.strategy = strategy
        self.rollbackStalledTurn = rollbackStalledTurn
        self.maxAttempts = max(1, maxAttempts)
        self.reminder = reminder
        self.behavioralInjectAfterStalls = max(1, behavioralInjectAfterStalls)
        self.behavioralRecoveryTemperature = behavioralRecoveryTemperature
    }
}

public struct ModeProfileTerminationSlice: Sendable, Equatable {
    public var policy: ModeProfileTerminationPolicy
    public var recovery: ModeProfileTerminationRecoverySlice?

    public init(
        policy: ModeProfileTerminationPolicy,
        recovery: ModeProfileTerminationRecoverySlice? = nil
    ) {
        self.policy = policy
        self.recovery = recovery
    }

    public static let bareMessageDefault = ModeProfileTerminationSlice(policy: .bareMessage)
}

/// Runtime policy slice for mode-specific turn-loop behavior.
///
/// These values are resolved from the mode profile (after `extends` flattening) and consumed by
/// runtime policy evaluators and orchestrator invocation setup.
///
/// Use this slice to control how a mode bounds and continues work during a turn:
/// - ``maxIterations`` bounds inner agentic/model-tool loop steps per update.
/// - ``stopOnApprovalRequest`` controls whether a turn should stop when any tool requires approval.
/// - ``termination`` controls how a turn can naturally terminate.
public struct ModeProfileRuntimeSlice: Sendable, Equatable {
    /// Maximum inner-loop iterations allowed for a single runtime update (single conversation turn).
    ///
    /// - `nil`: no mode-imposed cap; ``TurnLoop`` uses `Int.max` (other guardrails may still stop the turn).
    /// - non-`nil`: the mode imposes an explicit per-update iteration bound.
    public var maxIterations: Int?
    /// Whether a turn should stop when at least one tool requires approval.
    ///
    /// - `nil`: no explicit mode override.
    /// - `true`: stop with `stop_on_approval_request` when approval-required tools are detected.
    /// - `false`: do not stop solely due to approval-required tools.
    public var stopOnApprovalRequest: Bool?
    /// Declarative turn-termination policy.
    public var termination: ModeProfileTerminationSlice?

    /// Creates a runtime policy slice.
    ///
    /// - Parameters:
    ///   - maxIterations: Maximum inner-loop iterations per update, or `nil` for no mode cap.
    ///   - stopOnApprovalRequest: Whether approval-required tools should terminate the turn, or `nil` for default behavior.
    ///   - termination: Declarative turn-termination policy, or `nil` to use runtime defaults.
    public init(
        maxIterations: Int? = nil,
        stopOnApprovalRequest: Bool? = nil,
        termination: ModeProfileTerminationSlice? = nil
    ) {
        self.maxIterations = maxIterations
        self.stopOnApprovalRequest = stopOnApprovalRequest
        self.termination = termination
    }

    public static let neutral = ModeProfileRuntimeSlice()
}

/// Model-pool slice (query labels — persisted on profile only; composition with per-conversation overrides is product-owned).
public struct ModeProfileModelSlice: Sendable, Equatable {
    public var query: String?
    public var fallback: String?
    public var thinkingConfig: ThinkingConfig?

    public init(
        query: String? = nil,
        fallback: String? = nil,
        thinkingConfig: ThinkingConfig? = nil
    ) {
        self.query = query
        self.fallback = fallback
        self.thinkingConfig = thinkingConfig
    }

    public static let neutral = ModeProfileModelSlice()
}

/// Sub-agent pool slice.
public struct ModeProfileSubAgentsSlice: Sendable, Equatable {
    /// Delegate-tool allow-list (`"*"` allows all; empty list denies all). Nil means no extra mode restriction.
    public var allow: [String]?
    public var maxDepth: Int?
    /// Registry profile id whose resolved ``interactionMode`` seeds isolated spawns when the request omits `interactionMode`.
    public var childModeOnSpawnProfileId: String?

    public init(
        allow: [String]? = nil,
        maxDepth: Int? = nil,
        childModeOnSpawnProfileId: String? = nil
    ) {
        self.allow = allow
        self.maxDepth = maxDepth
        self.childModeOnSpawnProfileId = childModeOnSpawnProfileId
    }

    /// Harness default: prefer **agent** child mode rather than silently inheriting the parent conversation mode.
    public static func harnessDefaultChildSpawnSeed() -> ModeProfileSubAgentsSlice {
        ModeProfileSubAgentsSlice(
            allow: ["*"],
            maxDepth: nil,
            childModeOnSpawnProfileId: InteractionMode.agent.rawValue
        )
    }

    public static let neutral = ModeProfileSubAgentsSlice(allow: nil, maxDepth: nil, childModeOnSpawnProfileId: nil)
}

/// Transition-hook registry ids consumed by the conversation manager.
public struct ModeProfileTransitionHooksSlice: Sendable, Equatable {
    /// Ordered hook ids invoked before mode swap.
    public var onExit: [String]
    /// Ordered hook ids invoked after mode swap.
    public var onEnter: [String]

    public init(onExit: [String] = [], onEnter: [String] = []) {
        self.onExit = onExit
        self.onEnter = onEnter
    }

    public static let neutral = ModeProfileTransitionHooksSlice()
}

// MARK: - Resolved profile

/// Fully resolved mode profile (flattened ``extends`` chain).
public struct ResolvedModeProfile: Sendable, Equatable {
    public static let builtInSeedVersion = 1

    public var id: String
    public var interactionMode: InteractionMode
    public var assemblyKind: SystemPromptAssemblyKind
    /// When false, proactive context-compaction triggers are suppressed for **initial** phase assembly (chat stays light).
    public var allowsProactiveCompactionTriggers: Bool
    public var appliesAgentBuildOrchestratorHarness: Bool
    public var builtInSeedVersion: Int
    /// Optional harness-facing tags for layered mode profiles (`modes.md` forward-compat); empty when omitted from config.
    public var semanticLayerTags: [String]
    /// UI / picker metadata (nil → derive label from ``id``).
    public var label: String?
    public var profileDescription: String?
    public var symbol: String?

    public var tools: ModeProfileToolsSlice
    public var skills: ModeProfileSkillsSlice
    public var context: ModeProfileContextSlice
    public var runtime: ModeProfileRuntimeSlice
    public var model: ModeProfileModelSlice
    public var subAgents: ModeProfileSubAgentsSlice
    public var hooks: ModeProfileTransitionHooksSlice

    public var pickerLabel: String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }

    public init(
        id: String,
        interactionMode: InteractionMode,
        assemblyKind: SystemPromptAssemblyKind,
        allowsProactiveCompactionTriggers: Bool,
        appliesAgentBuildOrchestratorHarness: Bool,
        builtInSeedVersion: Int,
        semanticLayerTags: [String],
        label: String? = nil,
        profileDescription: String? = nil,
        symbol: String? = nil,
        tools: ModeProfileToolsSlice = .neutral,
        skills: ModeProfileSkillsSlice = .neutral,
        context: ModeProfileContextSlice = .neutral,
        runtime: ModeProfileRuntimeSlice = .neutral,
        model: ModeProfileModelSlice = .neutral,
        subAgents: ModeProfileSubAgentsSlice = .neutral,
        hooks: ModeProfileTransitionHooksSlice = .neutral
    ) {
        self.id = id
        self.interactionMode = interactionMode
        self.assemblyKind = assemblyKind
        self.allowsProactiveCompactionTriggers = allowsProactiveCompactionTriggers
        self.appliesAgentBuildOrchestratorHarness = appliesAgentBuildOrchestratorHarness
        self.builtInSeedVersion = builtInSeedVersion
        self.semanticLayerTags = semanticLayerTags
        self.label = label
        self.profileDescription = profileDescription
        self.symbol = symbol
        self.tools = tools
        self.skills = skills
        self.context = context
        self.runtime = runtime
        self.model = model
        self.subAgents = subAgents
        self.hooks = hooks
    }
}
