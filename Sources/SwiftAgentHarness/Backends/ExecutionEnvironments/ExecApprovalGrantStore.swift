import Foundation

/// Durable exec-approval grants keyed by grant command name (the inner command after
/// interpreter/wrapper peeling, or the first token for normal commands).
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
