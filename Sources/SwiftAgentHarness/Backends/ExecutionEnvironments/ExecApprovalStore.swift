import Foundation

public enum ExecApprovalResolution: Sendable, Equatable {
    case approved(durable: Bool)
    case denied(String)
}

public actor ExecApprovalStore {
    public static let shared = ExecApprovalStore()

    private struct PendingRequest: Sendable {
        let command: String
    }

    private var pending: [String: PendingRequest] = [:]
    private var waiters: [String: [CheckedContinuation<ExecApprovalResolution?, Never>]] = [:]
    private var grantStore: any ExecApprovalGrantStore

    public init(grantStore: any ExecApprovalGrantStore = InMemoryExecApprovalGrantStore()) {
        self.grantStore = grantStore
    }

    /// Swaps the backing grant store. Intended to be called once at host startup
    /// (e.g. on `ExecApprovalStore.shared`) before any approvals are processed.
    public func configure(grantStore: any ExecApprovalGrantStore) {
        self.grantStore = grantStore
    }

    public func registerPending(id: String, command: String) {
        pending[id] = PendingRequest(command: command)
    }

    public func isDurableApproved(command: String) async -> Bool {
        guard let name = Self.commandName(from: command) else { return false }
        return await grantStore.isGranted(commandName: name)
    }

    public func addDurableApproval(command: String) async {
        guard let name = Self.commandName(from: command) else { return }
        await grantStore.add(commandName: name)
    }

    @discardableResult
    public func resolve(
        id: String,
        approved: Bool,
        durable: Bool = false,
        reason: String? = nil
    ) async -> ExecApprovalResolution? {
        guard let request = pending.removeValue(forKey: id) else { return nil }
        let resolution: ExecApprovalResolution
        if approved {
            if durable {
                await addDurableApproval(command: request.command)
            }
            resolution = .approved(durable: durable)
        } else {
            resolution = .denied(reason ?? "denied")
        }
        resumeWaiters(for: id, resolution: resolution)
        return resolution
    }

    public func waitForResolution(id: String, timeoutSeconds: TimeInterval) async -> ExecApprovalResolution? {
        await withTaskGroup(of: ExecApprovalResolution?.self) { group in
            group.addTask {
                await self.awaitResolution(id: id)
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil {
                self.cancelWaiters(for: id)
            }
            return first
        }
    }

    private func awaitResolution(id: String) async -> ExecApprovalResolution? {
        await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    private func cancelWaiters(for id: String) {
        guard let continuations = waiters.removeValue(forKey: id) else { return }
        for continuation in continuations {
            continuation.resume(returning: nil)
        }
    }

    private func resumeWaiters(for id: String, resolution: ExecApprovalResolution) {
        guard let continuations = waiters.removeValue(forKey: id) else { return }
        for continuation in continuations {
            continuation.resume(returning: resolution)
        }
    }

    /// Extracts the command NAME (first executable token) from a full command
    /// string. Leading environment assignments are out of scope.
    static func commandName(from command: String) -> String? {
        command.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init)
    }
}
