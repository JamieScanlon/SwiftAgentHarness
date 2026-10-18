import Foundation

/// A named job the harness performs repeatedly; internal callers ask for a role, never a model (spec: roles).
public struct ModelRole: RawRepresentable, Sendable, Codable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let main: ModelRole = "main"
    public static let subagent: ModelRole = "subagent"
    public static let backgroundSmall: ModelRole = "background-small"
    public static let compactor: ModelRole = "compactor"
    public static let recall: ModelRole = "recall"
    public static let gatekeeper: ModelRole = "gatekeeper"
    public static let guardrail: ModelRole = "guard"
    public static let router: ModelRole = "router"
    public static let skillFilter: ModelRole = "skill-filter"
    public static let memoryGate: ModelRole = "memory-gate"
    public static let reranker: ModelRole = "reranker"
    public static let parser: ModelRole = "parser"
    public static let visionDescribe: ModelRole = "vision-describe"
    public static let transcriber: ModelRole = "transcriber"
    public static let speaker: ModelRole = "speaker"
    public static let voiceSession: ModelRole = "voice-session"
    public static let image: ModelRole = "image"
    public static let video: ModelRole = "video"
    public static let computerUse: ModelRole = "computer-use"
    public static let grounder: ModelRole = "grounder"

    public static func embedder(space: String) -> ModelRole {
        ModelRole(rawValue: "embedder:\(space)")
    }

    public var embeddingSpace: String? {
        guard rawValue.hasPrefix("embedder:") else { return nil }
        let space = String(rawValue.dropFirst("embedder:".count))
        return space.isEmpty ? nil : space
    }

    /// Roles feeding a permission or safety decision. Their thinking is always disabled.
    public var isSafetyCritical: Bool {
        self == .gatekeeper || self == .guardrail
    }

    /// Contract of a well-known role; `nil` for host-defined roles.
    public var wellKnownContract: ModelContract? {
        if embeddingSpace != nil { return .embed }
        switch self {
        case .main, .subagent, .backgroundSmall, .compactor, .recall, .visionDescribe, .computerUse, .grounder:
            return .generate
        case .gatekeeper, .guardrail, .router, .skillFilter, .memoryGate:
            return .decide
        case .reranker: return .rerank
        case .parser: return .parse
        case .transcriber: return .transcribe
        case .speaker, .image, .video: return .render
        case .voiceSession: return .session
        default: return nil
        }
    }

    /// Default when the host binds nothing (spec: well-known roles table).
    public var defaultWhenUnbound: RoleDefault {
        switch self {
        case .main: return .required
        case .subagent: return .role(.main)
        case .compactor: return .chain([.backgroundSmall, .main])
        case .recall: return .role(.backgroundSmall)
        case .computerUse: return .role(.main)
        default: return .off
        }
    }

    /// Background roles whose thinking defaults to disabled and may opt in only through an explicit binding.
    public var isBackground: Bool {
        self == .backgroundSmall || self == .compactor || self == .recall
    }
}

/// What an unbound role resolves to.
public enum RoleDefault: Sendable, Equatable {
    /// The host must bind it.
    case required
    /// Fall back to another role's binding.
    case role(ModelRole)
    /// Try roles in order.
    case chain([ModelRole])
    /// The consuming layer is off (gatekeeper, guard, router, embedder, …).
    case off
}

/// At most one escalation stage (spec: `RoleBinding.cascade`). For `decide` roles it is derived from the
/// consuming policy's ``DecisionPolicy/escalate`` rather than set separately.
public struct RoleCascade: Sendable, Codable, Hashable {
    public var to: String
    public var when: DeferralCondition

    public init(to: String, when: DeferralCondition) {
        self.to = to
        self.when = when
    }
}

public struct RoleBudget: Sendable, Codable, Hashable {
    public var maxUSDPerCall: Double?
    public var maxLatencyMs: Double?

    public init(maxUSDPerCall: Double? = nil, maxLatencyMs: Double? = nil) {
        self.maxUSDPerCall = maxUSDPerCall
        self.maxLatencyMs = maxLatencyMs
    }
}

public enum RolePriority: String, Sendable, Codable, Hashable {
    case foreground
    case background

    public var requestPriority: ModelRequestPriority {
        switch self {
        case .foreground: return .foreground
        case .background: return .background
        }
    }
}

/// A host binding of a role to models (spec: `RoleBinding`).
public struct RoleBinding: Sendable, Codable, Hashable {
    public var role: ModelRole
    public var contract: ModelContract
    public var minGuarantee: OutputGuarantee?
    public var query: ContractQuery
    /// Explicit model id or slug; must satisfy the contract and `minGuarantee`.
    public var pin: String?
    /// Ordered ids. For compat-bound roles, same `compatGroup` only.
    public var fallback: [String]
    public var cascade: RoleCascade?
    public var priority: RolePriority
    public var thinking: ThinkingConfig?
    public var locality: RoleLocality
    public var budget: RoleBudget?

    public init(
        role: ModelRole,
        contract: ModelContract,
        minGuarantee: OutputGuarantee? = nil,
        query: ContractQuery? = nil,
        pin: String? = nil,
        fallback: [String] = [],
        cascade: RoleCascade? = nil,
        priority: RolePriority = .background,
        thinking: ThinkingConfig? = nil,
        locality: RoleLocality = .any,
        budget: RoleBudget? = nil
    ) {
        self.role = role
        self.contract = contract
        self.minGuarantee = minGuarantee
        self.query = query ?? ContractQuery(contract: contract, minGuarantee: minGuarantee)
        self.pin = pin
        self.fallback = fallback
        self.cascade = cascade
        self.priority = priority
        self.thinking = thinking
        self.locality = locality
        self.budget = budget
    }

    /// Embedders and threshold-bearing decide roles may only fall back inside one compat group.
    public func isCompatBound(policy: DecisionPolicy?) -> Bool {
        if role.embeddingSpace != nil || contract == .embed { return true }
        if contract == .decide, let policy, !policy.bands.isEmpty { return true }
        return false
    }

    /// The thinking rule for roles: decide roles and safety-critical roles never think; background roles default
    /// to disabled and opt in only through an explicit binding; everything else inherits (`nil`).
    public var effectiveThinking: ThinkingConfig? {
        if contract == .decide || role.isSafetyCritical { return .disabled }
        if role.isBackground { return thinking ?? .disabled }
        return thinking
    }
}

/// Partial override of a role binding applied by a mode profile or conversation (later layers win per field).
public struct RoleBindingPatch: Sendable, Codable, Hashable {
    public var minGuarantee: OutputGuarantee?
    public var query: ContractQuery?
    public var pin: String?
    public var fallback: [String]?
    public var cascade: RoleCascade?
    public var priority: RolePriority?
    public var thinking: ThinkingConfig?
    public var locality: RoleLocality?
    public var budget: RoleBudget?

    public init(
        minGuarantee: OutputGuarantee? = nil,
        query: ContractQuery? = nil,
        pin: String? = nil,
        fallback: [String]? = nil,
        cascade: RoleCascade? = nil,
        priority: RolePriority? = nil,
        thinking: ThinkingConfig? = nil,
        locality: RoleLocality? = nil,
        budget: RoleBudget? = nil
    ) {
        self.minGuarantee = minGuarantee
        self.query = query
        self.pin = pin
        self.fallback = fallback
        self.cascade = cascade
        self.priority = priority
        self.thinking = thinking
        self.locality = locality
        self.budget = budget
    }

    func applied(to binding: RoleBinding) -> RoleBinding {
        var next = binding
        if let minGuarantee {
            next.minGuarantee = minGuarantee
            next.query.minGuarantee = minGuarantee
        }
        if let query { next.query = query }
        if let pin { next.pin = pin }
        if let fallback { next.fallback = fallback }
        if let cascade { next.cascade = cascade }
        if let priority { next.priority = priority }
        if let thinking { next.thinking = thinking }
        if let locality { next.locality = locality }
        if let budget { next.budget = budget }
        return next
    }
}

extension ThinkingConfig: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .disabled:
            hasher.combine(0)
        case .adaptive:
            hasher.combine(1)
        case .level(let level, let budgetTokens):
            hasher.combine(2)
            hasher.combine(level)
            hasher.combine(budgetTokens)
        }
    }
}

/// Resolves a role through the layer chain (later wins): built-in default → harness settings → mode-profile patch →
/// conversation patch → per-call pin.
public struct RoleBindingResolver: Sendable {
    public var settings: [ModelRole: RoleBinding]
    public var modePatches: [ModelRole: RoleBindingPatch]
    public var conversationPatches: [ModelRole: RoleBindingPatch]

    public init(
        settings: [ModelRole: RoleBinding] = [:],
        modePatches: [ModelRole: RoleBindingPatch] = [:],
        conversationPatches: [ModelRole: RoleBindingPatch] = [:]
    ) {
        self.settings = settings
        self.modePatches = modePatches
        self.conversationPatches = conversationPatches
    }

    /// Returns `nil` when the role is unbound and its default is ``RoleDefault/off`` or ``RoleDefault/required``.
    public func resolve(_ role: ModelRole, pin: String? = nil) -> RoleBinding? {
        guard var binding = baseBinding(for: role, visited: []) else { return nil }
        if binding.role != role {
            // Inherited from a default-chain role: keep that role's models but this role's identity and thinking rule.
            binding.role = role
            binding.thinking = nil
        }
        if let patch = modePatches[role] { binding = patch.applied(to: binding) }
        if let patch = conversationPatches[role] { binding = patch.applied(to: binding) }
        if let pin { binding.pin = pin }
        return binding
    }

    private func baseBinding(for role: ModelRole, visited: Set<ModelRole>) -> RoleBinding? {
        if let bound = settings[role] { return bound }
        if modePatches[role] != nil || conversationPatches[role] != nil, let contract = role.wellKnownContract {
            return RoleBinding(role: role, contract: contract)
        }
        guard !visited.contains(role) else { return nil }
        let nextVisited = visited.union([role])
        switch role.defaultWhenUnbound {
        case .required, .off:
            return nil
        case .role(let other):
            return baseBinding(for: other, visited: nextVisited)
        case .chain(let roles):
            for other in roles {
                if let binding = baseBinding(for: other, visited: nextVisited) { return binding }
            }
            return nil
        }
    }
}
