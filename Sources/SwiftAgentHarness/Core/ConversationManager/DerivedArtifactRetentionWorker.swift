import Foundation

public struct DerivedArtifactRetentionPolicy: Sendable {
    public var supersededOnly: Bool
    public var pruneOrphans: Bool
    public var batchLimit: Int
    public var ttlSecondsForDerivedEvents: Double?
    public var ttlSecondsForSnapshots: Double?

    public init(
        supersededOnly: Bool = true,
        pruneOrphans: Bool = true,
        batchLimit: Int = 500,
        ttlSecondsForDerivedEvents: Double? = nil,
        ttlSecondsForSnapshots: Double? = nil
    ) {
        self.supersededOnly = supersededOnly
        self.pruneOrphans = pruneOrphans
        self.batchLimit = max(1, batchLimit)
        self.ttlSecondsForDerivedEvents = ttlSecondsForDerivedEvents
        self.ttlSecondsForSnapshots = ttlSecondsForSnapshots
    }
}

public struct DerivedArtifactRetentionSweepResult: Sendable, Equatable {
    public var deletedDerivedEvents: Int = 0
    public var deletedSnapshots: Int = 0
    public var deletedOrphanDerivedEvents: Int = 0
    public var deletedOrphanSnapshots: Int = 0

    public var totalDeletedRows: Int {
        deletedDerivedEvents + deletedSnapshots + deletedOrphanDerivedEvents + deletedOrphanSnapshots
    }
}

/// Physical journal prune on harness transcript rows; logical supersession remains invalidation-floor driven.
struct DerivedArtifactRetentionWorker {
    private let harness: (any HarnessSessionPersistence)?

    init(harness: (any HarnessSessionPersistence)? = nil) {
        self.harness = harness
    }

    func runSweep(
        policy: DerivedArtifactRetentionPolicy,
        knownConversationIDs: Set<UUID>? = nil
    ) throws -> DerivedArtifactRetentionSweepResult {
        guard let harness else { return DerivedArtifactRetentionSweepResult() }
        let ids: [UUID]
        if let knownConversationIDs, !knownConversationIDs.isEmpty {
            ids = Array(knownConversationIDs.prefix(policy.batchLimit))
        } else {
            ids = try harness.listCatalogConversations().map(\.id).prefix(policy.batchLimit).map { $0 }
        }
        var result = DerivedArtifactRetentionSweepResult()
        for conversationID in ids {
            let pruned = try TranscriptJournalRetentionPruner.pruneConversation(
                conversationID: conversationID,
                harness: harness,
                policy: policy
            )
            result.deletedDerivedEvents += pruned.deletedDerived
            result.deletedSnapshots += pruned.deletedSnapshots
        }
        _ = policy.pruneOrphans
        _ = (policy.ttlSecondsForDerivedEvents, policy.ttlSecondsForSnapshots)
        return result
    }
}
