import Foundation

/// Durable exec-approval grants keyed by command name (the first executable token).
///
/// Hosts can supply a persistent implementation so that durable grants survive
/// restarts and apply across differing arguments for the same command. The
/// default in-memory implementation preserves the historical behavior.
public protocol ExecApprovalGrantStore: Sendable {
    func isGranted(commandName: String) async -> Bool
    func add(commandName: String) async
    func remove(commandName: String) async
    func list() async -> [String]
}

/// Default in-memory grant store. Grants live only for the process lifetime.
public actor InMemoryExecApprovalGrantStore: ExecApprovalGrantStore {
    private var commandNames: Set<String>

    public init(commandNames: Set<String> = []) {
        self.commandNames = commandNames
    }

    public func isGranted(commandName: String) async -> Bool {
        commandNames.contains(commandName)
    }

    public func add(commandName: String) async {
        commandNames.insert(commandName)
    }

    public func remove(commandName: String) async {
        commandNames.remove(commandName)
    }

    public func list() async -> [String] {
        commandNames.sorted()
    }
}
