import Foundation

/// How long a computer-use run's images survive: its screenshots, replay thumbnails, and replay document.
///
/// Each holder of an image keeps its own reference with its own expiry, and the image goes when the last one
/// expires. While the lease is active, the session's reference expires `afterRelease` past the lease's hard limit
/// (its current end time plus the cleanup grace) and moves when the time ceiling does, so a crash can't keep images
/// forever. At release the session's and the replay's references run for `afterRelease`, and an audit mark adds
/// one for `audit`.
public struct ComputerUseRetention: Sendable, Equatable {
    public var afterRelease: Duration
    /// Retention from release for audit-marked runs: a fixed length, never indefinite.
    public var audit: Duration

    public init(afterRelease: Duration = .seconds(24 * 3_600), audit: Duration = .seconds(30 * 86_400)) {
        self.afterRelease = afterRelease
        self.audit = audit
    }

    /// When a released run's images expire.
    public func expiry(releasedAt: Date, auditMarked: Bool) -> Date {
        let normal = releasedAt.addingTimeInterval(afterRelease.timeInterval)
        guard auditMarked else { return normal }
        return max(normal, releasedAt.addingTimeInterval(audit.timeInterval))
    }
}

/// Every computer-use reference to every image blob, each with its own expiry, and audit marks placed before the
/// run was released. A blob's expiry in the store is the latest of its references.
actor ComputerUseBlobLedger {
    enum Holder: Hashable, Sendable {
        /// The live specialist session, by its child conversation.
        case session(UUID)
        case replay(parent: UUID, lifecycleID: String)
        case audit(parent: UUID, lifecycleID: String)
    }

    /// A blob's expiry after a reference changed, for the caller to write to the store.
    struct Expiry: Sendable, Equatable {
        var blobID: String
        var expiresAt: Date
    }

    private struct RunKey: Hashable {
        var parent: UUID
        var lifecycleID: String
    }

    private let now: @Sendable () -> Date
    private var references: [String: [Holder: Date]] = [:]
    private var sessionBlobs: [UUID: [String]] = [:]
    private var auditMarks: Set<RunKey> = []

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Sets `holder`'s reference on `blobIDs` to expire at `expiresAt`, or removes it when `nil`. A blob left with
    /// no reference expires now.
    func reference(_ blobIDs: [String], by holder: Holder, until expiresAt: Date?) -> [Expiry] {
        Array(Set(blobIDs)).sorted().map { blobID in
            references[blobID, default: [:]][holder] = expiresAt
            let latest = references[blobID]?.values.max()
            if latest == nil { references[blobID] = nil }
            return Expiry(blobID: blobID, expiresAt: latest ?? now())
        }
    }

    /// The session's reference on images its child stored.
    func hold(_ blobIDs: [String], childConversationID: UUID, until expiresAt: Date) -> [Expiry] {
        guard !blobIDs.isEmpty else { return [] }
        sessionBlobs[childConversationID, default: []].append(contentsOf: blobIDs)
        return reference(blobIDs, by: .session(childConversationID), until: expiresAt)
    }

    /// Moves the session's reference on everything its child stored, as when the time ceiling moves.
    func moveSession(childConversationID: UUID, until expiresAt: Date) -> [Expiry] {
        reference(sessionBlobs[childConversationID] ?? [], by: .session(childConversationID), until: expiresAt)
    }

    /// The images the session's child stored, forgetting the list; the references stay.
    func takeHeld(childConversationID: UUID) -> [String] {
        sessionBlobs.removeValue(forKey: childConversationID) ?? []
    }

    func holds(_ blobID: String, childConversationID: UUID) -> Bool {
        sessionBlobs[childConversationID]?.contains(blobID) == true
    }

    func expiry(of blobID: String) -> Date? {
        references[blobID]?.values.max()
    }

    func setAuditMark(_ marked: Bool, parent: UUID, lifecycleID: String) {
        let key = RunKey(parent: parent, lifecycleID: lifecycleID)
        if marked { auditMarks.insert(key) } else { auditMarks.remove(key) }
    }

    func takeAuditMark(parent: UUID, lifecycleID: String) -> Bool {
        auditMarks.remove(RunKey(parent: parent, lifecycleID: lifecycleID)) != nil
    }
}
