import Foundation

/// How long a computer-use run's images survive: its screenshots, replay thumbnails, and replay document.
///
/// They are held while the run can still reference them, until the lease's hard expiry at the latest so a crash
/// can't keep them forever. When the lease is released, the `afterRelease` TTL starts. Runs the user marks for
/// audit get `audit` instead.
public struct ComputerUseRetention: Sendable, Equatable {
    public var afterRelease: Duration
    /// Retention from release for audit-marked runs; `nil` keeps them until the mark is removed.
    public var audit: Duration?

    public init(afterRelease: Duration = .seconds(24 * 3_600), audit: Duration? = nil) {
        self.afterRelease = afterRelease
        self.audit = audit
    }

    /// When a released run's images expire; `nil` holds them.
    public func expiry(releasedAt: Date, auditMarked: Bool) -> Date? {
        guard auditMarked else { return releasedAt.addingTimeInterval(afterRelease.timeInterval) }
        return audit.map { releasedAt.addingTimeInterval($0.timeInterval) }
    }
}

/// Per-run bookkeeping for the retention lifecycle: the screenshot blobs a live run stored, and audit marks
/// placed before the run was released.
actor ComputerUseBlobLedger {
    private struct RunKey: Hashable {
        var parent: UUID
        var lifecycleID: String
    }

    private var held: [UUID: [String]] = [:]
    private var auditMarks: Set<RunKey> = []

    func hold(_ blobIDs: [String], childConversationID: UUID) {
        guard !blobIDs.isEmpty else { return }
        held[childConversationID, default: []].append(contentsOf: blobIDs)
    }

    func takeHeld(childConversationID: UUID) -> [String] {
        held.removeValue(forKey: childConversationID) ?? []
    }

    func setAuditMark(_ marked: Bool, parent: UUID, lifecycleID: String) {
        let key = RunKey(parent: parent, lifecycleID: lifecycleID)
        if marked { auditMarks.insert(key) } else { auditMarks.remove(key) }
    }

    func takeAuditMark(parent: UUID, lifecycleID: String) -> Bool {
        auditMarks.remove(RunKey(parent: parent, lifecycleID: lifecycleID)) != nil
    }
}
