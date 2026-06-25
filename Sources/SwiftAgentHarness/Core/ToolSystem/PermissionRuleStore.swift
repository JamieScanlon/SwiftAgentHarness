import Foundation

/// The scope of a persisted `allow-always` permission rule. Replaces the
/// first-token-only exec grant model with a vocabulary that can pin a rule to a
/// specific tool, a command name, an exact command line, or a directory.
public enum PermissionRuleScope: Sendable, Codable, Equatable, Hashable {
    case toolName(String)
    case commandName(String)
    case exactCommand(String)
    case directory(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case toolName
        case commandName
        case exactCommand
        case directory
    }

    public var value: String {
        switch self {
        case .toolName(let value), .commandName(let value), .exactCommand(let value), .directory(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case .toolName: self = .toolName(value)
        case .commandName: self = .commandName(value)
        case .exactCommand: self = .exactCommand(value)
        case .directory: self = .directory(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let kind: Kind
        switch self {
        case .toolName: kind = .toolName
        case .commandName: kind = .commandName
        case .exactCommand: kind = .exactCommand
        case .directory: kind = .directory
        }
        try container.encode(kind, forKey: .kind)
        try container.encode(value, forKey: .value)
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
    /// Tool-name grants currently in the store, for merging into the run's
    /// pre-approved tool set.
    public func grantedToolNames() async -> Set<String> {
        let scopes = await list()
        return Set(scopes.compactMap { scope -> String? in
            if case .toolName(let name) = scope { return name }
            return nil
        })
    }
}

/// Default in-memory permission rule store. Rules live for the process lifetime.
public actor InMemoryPermissionRuleStore: PermissionRuleStore {
    private var rules: Set<PermissionRuleScope>

    public init(rules: Set<PermissionRuleScope> = []) {
        self.rules = rules
    }

    public func isGranted(_ scope: PermissionRuleScope) async -> Bool {
        rules.contains(scope)
    }

    public func add(_ scope: PermissionRuleScope) async {
        rules.insert(scope)
    }

    public func remove(_ scope: PermissionRuleScope) async {
        rules.remove(scope)
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
        return rules.contains(scope)
    }

    public func add(_ scope: PermissionRuleScope) async {
        loadIfNeeded()
        guard !rules.contains(scope) else { return }
        rules.insert(scope)
        persist()
    }

    public func remove(_ scope: PermissionRuleScope) async {
        loadIfNeeded()
        guard rules.contains(scope) else { return }
        rules.remove(scope)
        persist()
    }

    public func list() async -> [PermissionRuleScope] {
        loadIfNeeded()
        return rules.sorted { $0.value < $1.value }
    }
}

/// Adapts a `PermissionRuleStore` to the exec-approval grant interface so durable
/// exec grants can share the scopable, persistable rule backend. Command-name
/// grants map onto `.commandName` scopes, preserving the historical "any args for
/// this command" semantics while gaining persistence and a shared vocabulary.
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
