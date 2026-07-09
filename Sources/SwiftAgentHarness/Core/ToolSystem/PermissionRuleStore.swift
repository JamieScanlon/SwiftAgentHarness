import EasyJSON
import Foundation

/// The scope of a persisted `allow-always` permission rule. Replaces the
/// first-token-only exec grant model with a vocabulary that can pin a rule to a
/// specific tool, a command name, an exact command line, or a directory.
public enum PermissionRuleScope: Sendable, Codable, Equatable, Hashable {
    case toolName(String)
    /// Owner-scoped durable tool grant (DEF-122 / SEC-011).
    case ownerToolName(ownerAccountID: UUID, toolName: String)
    /// Full grammar durable grant (`bash(npm test)`, `group:fs`, etc.).
    case toolRule(ToolPolicyRule, ownerAccountID: UUID?)
    case commandName(String)
    case exactCommand(String)
    case directory(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case ownerAccountID
        case toolName
        case toolRule
    }

    private enum Kind: String, Codable {
        case toolName
        case ownerToolName
        case toolRule
        case commandName
        case exactCommand
        case directory
    }

    public var value: String {
        switch self {
        case .toolName(let value), .commandName(let value), .exactCommand(let value), .directory(let value):
            return value
        case .ownerToolName(let ownerAccountID, let toolName):
            return "\(ownerAccountID.uuidString)|\(toolName)"
        case .toolRule(let rule, let ownerAccountID):
            if let ownerAccountID {
                return "\(ownerAccountID.uuidString)|\(rule.rawToken)"
            }
            return rule.rawToken
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .toolName:
            let value = try container.decode(String.self, forKey: .value)
            self = .toolName(value)
        case .ownerToolName:
            let ownerAccountID = try container.decode(UUID.self, forKey: .ownerAccountID)
            let toolName = try container.decode(String.self, forKey: .toolName)
            self = .ownerToolName(ownerAccountID: ownerAccountID, toolName: toolName)
        case .toolRule:
            let rule = try container.decode(ToolPolicyRule.self, forKey: .toolRule)
            let ownerAccountID = try container.decodeIfPresent(UUID.self, forKey: .ownerAccountID)
            self = .toolRule(rule, ownerAccountID: ownerAccountID)
        case .commandName:
            let value = try container.decode(String.self, forKey: .value)
            self = .commandName(value)
        case .exactCommand:
            let value = try container.decode(String.self, forKey: .value)
            self = .exactCommand(value)
        case .directory:
            let value = try container.decode(String.self, forKey: .value)
            self = .directory(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toolName(let value):
            try container.encode(Kind.toolName, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .ownerToolName(let ownerAccountID, let toolName):
            try container.encode(Kind.ownerToolName, forKey: .kind)
            try container.encode(ownerAccountID, forKey: .ownerAccountID)
            try container.encode(toolName, forKey: .toolName)
        case .toolRule(let rule, let ownerAccountID):
            try container.encode(Kind.toolRule, forKey: .kind)
            try container.encode(rule, forKey: .toolRule)
            try container.encodeIfPresent(ownerAccountID, forKey: .ownerAccountID)
        case .commandName(let value):
            try container.encode(Kind.commandName, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .exactCommand(let value):
            try container.encode(Kind.exactCommand, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .directory(let value):
            try container.encode(Kind.directory, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    /// Whether two tool-grant scopes match after canonical name resolution.
    func matchesToolGrant(_ other: PermissionRuleScope) -> Bool {
        switch (self, other) {
        case (.toolName(let stored), .toolName(let requested)):
            return ToolNamePolicyNormalization.canonical(stored)
                == ToolNamePolicyNormalization.canonical(requested)
        case (.ownerToolName(let ownerStored, let stored), .ownerToolName(let ownerRequested, let requested)):
            return ownerStored == ownerRequested
                && ToolNamePolicyNormalization.canonical(stored)
                    == ToolNamePolicyNormalization.canonical(requested)
        case (.toolRule(let storedRule, let ownerStored), .toolRule(let requestedRule, let ownerRequested)):
            return ownerStored == ownerRequested && storedRule == requestedRule
        default:
            return self == other
        }
    }

    /// Whether this scope matches a call via the full rule grammar.
    func matchesCall(
        entry: ToolRegistryEntry,
        arguments: JSON,
        groupIndex: ToolPolicyGroupIndex
    ) -> Bool {
        switch self {
        case .toolRule(let rule, _):
            return ToolPolicyCallMatcher.matches(
                rule: rule,
                entry: entry,
                arguments: arguments,
                groupIndex: groupIndex
            )
        case .toolName(let name):
            return ToolNamePolicyNormalization.canonical(entry.name)
                == ToolNamePolicyNormalization.canonical(name)
        case .ownerToolName(_, let name):
            return ToolNamePolicyNormalization.canonical(entry.name)
                == ToolNamePolicyNormalization.canonical(name)
        case .commandName(let commandName):
            let values = ToolPolicyArgumentExtractor.extractedValues(
                toolName: entry.name,
                arguments: arguments
            )
            return values.contains { value in
                if let grantName = ExecApprovalGrantCommandName.durableGrantCommandName(from: value) {
                    return grantName == commandName
                }
                return value == commandName
            }
        case .exactCommand, .directory:
            return false
        }
    }

    /// Canonical tool name when this scope refers to a tool grant.
    var canonicalToolName: String? {
        switch self {
        case .toolName(let name):
            return ToolNamePolicyNormalization.canonical(name)
        case .ownerToolName(_, let name):
            return ToolNamePolicyNormalization.canonical(name)
        case .toolRule(let rule, _):
            return rule.canonicalToolName
        case .commandName, .exactCommand, .directory:
            return nil
        }
    }

    /// Whether this scope matches another, using canonical resolution for tool grants.
    func scopesMatch(_ other: PermissionRuleScope) -> Bool {
        if canonicalToolName != nil || other.canonicalToolName != nil {
            return matchesToolGrant(other)
        }
        return self == other
    }
}

/// A persisted permission rule that auto-approves matching future calls.
public protocol PermissionRuleStore: Sendable {
    func isGranted(_ scope: PermissionRuleScope) async -> Bool
    func add(_ scope: PermissionRuleScope) async
    func remove(_ scope: PermissionRuleScope) async
    func list() async -> [PermissionRuleScope]
}

extension PermissionRuleStore {
    /// Resolves the persisted scope for a durable tool grant.
    static func toolGrantScope(
        toolName: String,
        ownerAccountID: UUID?,
        strictTenancy: Bool
    ) -> PermissionRuleScope? {
        let canonicalName = ToolNamePolicyNormalization.canonical(toolName)
        if strictTenancy {
            guard let ownerAccountID else { return nil }
            return .ownerToolName(ownerAccountID: ownerAccountID, toolName: canonicalName)
        }
        if let ownerAccountID {
            return .ownerToolName(ownerAccountID: ownerAccountID, toolName: canonicalName)
        }
        return .toolName(canonicalName)
    }

    /// Owner-scoped tool-name grants for merging into the run's pre-approved tool set.
    public func grantedToolNames(ownerAccountID: UUID?, strictTenancy: Bool) async -> Set<String> {
        let scopes = await list()
        return Set(scopes.compactMap { scope -> String? in
            switch scope {
            case .toolName(let name):
                if strictTenancy { return nil }
                if ownerAccountID != nil { return nil }
                return ToolNamePolicyNormalization.canonical(name)
            case .ownerToolName(let owner, let name):
                if strictTenancy {
                    guard let ownerAccountID, owner == ownerAccountID else { return nil }
                    return ToolNamePolicyNormalization.canonical(name)
                }
                if let ownerAccountID {
                    return owner == ownerAccountID
                        ? ToolNamePolicyNormalization.canonical(name)
                        : nil
                }
                return nil
            case .toolRule(let rule, let owner):
                guard rule.isNameLevelRule, let name = rule.canonicalToolName else { return nil }
                if strictTenancy {
                    guard let ownerAccountID, owner == ownerAccountID else { return nil }
                    return name
                }
                if let ownerAccountID {
                    return owner == ownerAccountID ? name : nil
                }
                if owner == nil, case .bareName = rule {
                    return name
                }
                return nil
            case .commandName, .exactCommand, .directory:
                return nil
            }
        })
    }

    public func addToolGrant(toolName: String, ownerAccountID: UUID?, strictTenancy: Bool) async {
        guard let scope = Self.toolGrantScope(
            toolName: toolName,
            ownerAccountID: ownerAccountID,
            strictTenancy: strictTenancy
        ) else { return }
        await add(scope)
    }

    public func removeToolGrant(toolName: String, ownerAccountID: UUID?, strictTenancy: Bool) async {
        guard let scope = Self.toolGrantScope(
            toolName: toolName,
            ownerAccountID: ownerAccountID,
            strictTenancy: strictTenancy
        ) else { return }
        await remove(scope)
    }

    public func grantedToolRules(ownerAccountID: UUID?, strictTenancy: Bool) async -> [ToolPolicyRule] {
        let scopes = await list()
        return scopes.compactMap { scope -> ToolPolicyRule? in
            switch scope {
            case .toolRule(let rule, let owner):
                if strictTenancy {
                    guard let ownerAccountID, owner == ownerAccountID else { return nil }
                    return rule
                }
                if let ownerAccountID {
                    return owner == ownerAccountID ? rule : nil
                }
                return owner == nil ? rule : nil
            case .commandName(let commandName):
                return .argumentMatcher(toolName: "bash", pattern: commandName)
            default:
                return nil
            }
        }
    }

    public func addToolRuleGrant(
        rule: ToolPolicyRule,
        ownerAccountID: UUID?,
        strictTenancy: Bool
    ) async {
        if strictTenancy {
            guard let ownerAccountID else { return }
            await add(.toolRule(rule, ownerAccountID: ownerAccountID))
            return
        }
        await add(.toolRule(rule, ownerAccountID: ownerAccountID))
    }
}

enum ToolPolicyDurableRuleFactory {
    static func ruleFromApprovedCall(
        toolName: String,
        arguments: JSON
    ) -> ToolPolicyRule {
        let canonical = ToolNamePolicyNormalization.canonical(toolName)
        let values = ToolPolicyArgumentExtractor.extractedValues(toolName: canonical, arguments: arguments)
        if values.count == 1, !values[0].contains("&&"), !values[0].contains("|") {
            return .argumentMatcher(toolName: canonical, pattern: values[0])
        }
        return .bareName(canonical)
    }
}

/// Default in-memory permission rule store. Rules live for the process lifetime.
public actor InMemoryPermissionRuleStore: PermissionRuleStore {
    private var rules: Set<PermissionRuleScope>

    public init(rules: Set<PermissionRuleScope> = []) {
        self.rules = rules
    }

    public func isGranted(_ scope: PermissionRuleScope) async -> Bool {
        rules.contains { $0.scopesMatch(scope) }
    }

    public func add(_ scope: PermissionRuleScope) async {
        if scope.canonicalToolName != nil {
            rules = rules.filter { !$0.matchesToolGrant(scope) }
        }
        rules.insert(scope)
    }

    public func remove(_ scope: PermissionRuleScope) async {
        if scope.canonicalToolName != nil {
            rules = rules.filter { !$0.scopesMatch(scope) }
        } else {
            rules.remove(scope)
        }
    }

    public func list() async -> [PermissionRuleScope] {
        rules.sorted { lhs, rhs in
            lhs.value < rhs.value
        }
    }
}

/// Disk-backed permission rule store. Persists rules as JSON so `allow-always`
/// grants survive process restarts.
public actor FilePermissionRuleStore: PermissionRuleStore {
    private let fileURL: URL
    private var rules: Set<PermissionRuleScope>
    private var loaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.rules = []
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PermissionRuleScope].self, from: data)
        else { return }
        rules = Set(decoded)
    }

    private func persist() {
        let ordered = rules.sorted { $0.value < $1.value }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func isGranted(_ scope: PermissionRuleScope) async -> Bool {
        loadIfNeeded()
        return rules.contains { $0.scopesMatch(scope) }
    }

    public func add(_ scope: PermissionRuleScope) async {
        loadIfNeeded()
        if scope.canonicalToolName != nil {
            rules = rules.filter { !$0.matchesToolGrant(scope) }
        }
        guard !rules.contains(where: { $0.scopesMatch(scope) }) else { return }
        rules.insert(scope)
        persist()
    }

    public func remove(_ scope: PermissionRuleScope) async {
        loadIfNeeded()
        let hadMatch = rules.contains { $0.scopesMatch(scope) }
        guard hadMatch else { return }
        if scope.canonicalToolName != nil {
            rules = rules.filter { !$0.scopesMatch(scope) }
        } else {
            rules.remove(scope)
        }
        persist()
    }

    public func list() async -> [PermissionRuleScope] {
        loadIfNeeded()
        return rules.sorted { $0.value < $1.value }
    }
}

/// Adapts a `PermissionRuleStore` to the exec-approval grant interface so durable
/// exec grants can share the scopable, persistable rule backend. Grant keys map
/// onto `.commandName` scopes using post-peel inner command names while preserving
/// cross-argument grants for the same underlying command.
public actor PermissionRuleExecApprovalGrantStore: ExecApprovalGrantStore {
    private let store: any PermissionRuleStore

    public init(store: any PermissionRuleStore) {
        self.store = store
    }

    public func isGranted(commandName: String) async -> Bool {
        await store.isGranted(.commandName(commandName))
    }

    public func add(commandName: String) async {
        await store.add(.commandName(commandName))
    }

    public func remove(commandName: String) async {
        await store.remove(.commandName(commandName))
    }

    public func list() async -> [String] {
        let scopes = await store.list()
        return scopes.compactMap { scope -> String? in
            if case .commandName(let name) = scope { return name }
            return nil
        }.sorted()
    }
}
