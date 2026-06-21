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
    private var durableCommands: Set<String> = []

    public init() {}

    public func registerPending(id: String, command: String) {
        pending[id] = PendingRequest(command: command)
    }

    public func isDurableApproved(command: String) -> Bool {
        durableCommands.contains(Self.normalizeCommand(command))
    }

    public func addDurableApproval(command: String) {
        durableCommands.insert(Self.normalizeCommand(command))
    }

    @discardableResult
    public func resolve(
        id: String,
        approved: Bool,
        durable: Bool = false,
        reason: String? = nil
    ) -> ExecApprovalResolution? {
        guard let request = pending.removeValue(forKey: id) else { return nil }
        let resolution: ExecApprovalResolution
        if approved {
            if durable {
                addDurableApproval(command: request.command)
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

    private static func normalizeCommand(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
