import Foundation

/// File-based scheduler/channel lock. Read-then-write acquire can race (TOCTOU); cron task
/// `task.id:windowMs` dedup and trigger idempotency backstop duplicate firings when two processes
/// both believe they hold the lock.
struct SchedulerLockState: Codable, Equatable {
    var ownerPID: Int32
    var ownerStartToken: UInt64
    var bootKey: String
    var identity: String
    var acquiredAt: Date

    init(ownerPID: Int32, ownerStartToken: UInt64, bootKey: String, identity: String, acquiredAt: Date) {
        self.ownerPID = ownerPID
        self.ownerStartToken = ownerStartToken
        self.bootKey = bootKey
        self.identity = identity
        self.acquiredAt = acquiredAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ownerPID = try container.decode(Int32.self, forKey: .ownerPID)
        ownerStartToken = try container.decodeIfPresent(UInt64.self, forKey: .ownerStartToken) ?? 0
        bootKey = try container.decodeIfPresent(String.self, forKey: .bootKey) ?? ""
        identity = try container.decode(String.self, forKey: .identity)
        acquiredAt = try container.decode(Date.self, forKey: .acquiredAt)
    }
}

enum SchedulerLock {
    static let probeIntervalSeconds: TimeInterval = 5

    /// Is the recorded holder *this* process, not merely something with the same identity string?
    ///
    /// The sentinels (`ownerStartToken == 0`, empty `bootKey`) mean "written by a build that did not
    /// record this", and are treated as unknown-but-not-disqualifying — the same reading
    /// ``isHolderAlive`` gives them.
    static func isHeldByCurrentProcess(_ state: SchedulerLockState) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard state.ownerPID == pid else { return false }
        if state.ownerStartToken != 0, state.ownerStartToken != ProcessLockIdentity.startToken(for: pid) {
            return false
        }
        if !state.bootKey.isEmpty, state.bootKey != ProcessLockIdentity.currentBootKey() {
            return false
        }
        return true
    }

    /// - Parameter requireSameProcess: when true, a live holder satisfies the lock only if it is
    ///   *this* process. Channels need it; the cron scheduler does not, and defaulting to `false`
    ///   keeps its re-acquire semantics untouched.
    static func tryAcquire(lockURL: URL, identity: String, requireSameProcess: Bool = false) throws -> Bool {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try read(lockURL: lockURL) {
            if isHolderAlive(existing) {
                guard existing.identity == identity else { return false }
                // The identity is config-derived (`channel:platformIdentity`) and carries nothing
                // process-specific, so two gateways running the same bot both matched it and both
                // believed they held the lock. The spec requires the second to fail fatal.
                return requireSameProcess ? isHeldByCurrentProcess(existing) : true
            }
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let state = SchedulerLockState(
            ownerPID: pid,
            ownerStartToken: ProcessLockIdentity.startToken(for: pid),
            bootKey: ProcessLockIdentity.currentBootKey(),
            identity: identity,
            acquiredAt: Date()
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: lockURL, options: .atomic)
        return true
    }

    /// - Parameter requireSameProcess: when true, refuse to delete a lock file this process does not
    ///   own. Without it, a second gateway that wrongly believed it held the lock deleted the real
    ///   owner's file on the way out.
    static func release(lockURL: URL, identity: String, requireSameProcess: Bool = false) throws {
        guard let existing = try read(lockURL: lockURL), existing.identity == identity else { return }
        if requireSameProcess, isHolderAlive(existing), !isHeldByCurrentProcess(existing) { return }
        try? FileManager.default.removeItem(at: lockURL)
    }

    static func read(lockURL: URL) throws -> SchedulerLockState? {
        guard FileManager.default.fileExists(atPath: lockURL.path) else { return nil }
        let data = try Data(contentsOf: lockURL)
        return try JSONDecoder().decode(SchedulerLockState.self, from: data)
    }

    static func isProcessAlive(_ pid: Int32) -> Bool {
        ProcessLockIdentity.isPidAlive(pid)
    }

    static func isHolderAlive(_ state: SchedulerLockState) -> Bool {
        guard isProcessAlive(state.ownerPID) else { return false }
        guard state.ownerStartToken == 0 || ProcessLockIdentity.startToken(for: state.ownerPID) == state.ownerStartToken else {
            return false
        }
        if !state.bootKey.isEmpty, state.bootKey != ProcessLockIdentity.currentBootKey() {
            return false
        }
        return true
    }
}
