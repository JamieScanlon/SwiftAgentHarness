import Foundation

enum BranchJournalInheritanceRule: Sendable {
    case messageAppendedScoped
    case turnSummaryScoped
    case durableCheckpointScoped
    case rawPrefixScoped
    case copyVerbatim
    case omit
}

struct DerivedArtifactContract: Sendable {
    let persistedKind: String
    let invalidationKindKeys: [String]
    let branchInheritanceRule: BranchJournalInheritanceRule
    let retentionEligible: Bool
    let snapshotSupersessionEligible: Bool
}

enum DerivedArtifactContractMatrix: Sendable {
    private static let contractsByKind: [String: DerivedArtifactContract] = {
        let contracts: [DerivedArtifactContract] = [
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.messageAppended.rawValue,
                invalidationKindKeys: [],
                branchInheritanceRule: .messageAppendedScoped,
                retentionEligible: false,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.interactionModeChanged.rawValue,
                invalidationKindKeys: [],
                branchInheritanceRule: .rawPrefixScoped,
                retentionEligible: false,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.turnSummaryEvent.rawValue,
                invalidationKindKeys: [HarnessCheckpointInvalidationKind.turnSummaryEvent],
                branchInheritanceRule: .turnSummaryScoped,
                retentionEligible: true,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.turnFinalized.rawValue,
                invalidationKindKeys: [],
                branchInheritanceRule: .copyVerbatim,
                retentionEligible: false,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.compactionApplied.rawValue,
                invalidationKindKeys: [],
                branchInheritanceRule: .copyVerbatim,
                retentionEligible: false,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
                invalidationKindKeys: [
                    HarnessCheckpointInvalidationKind.contextCompaction,
                    HarnessCheckpointInvalidationKind.cacheAwarePruning,
                ],
                branchInheritanceRule: .durableCheckpointScoped,
                retentionEligible: true,
                snapshotSupersessionEligible: true
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue,
                invalidationKindKeys: [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot],
                branchInheritanceRule: .durableCheckpointScoped,
                retentionEligible: true,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.toolResultTrimCheckpoint.rawValue,
                invalidationKindKeys: [HarnessCheckpointInvalidationKind.toolResultTrim],
                branchInheritanceRule: .durableCheckpointScoped,
                retentionEligible: true,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
                invalidationKindKeys: [HarnessCheckpointInvalidationKind.systemPromptAssembly],
                branchInheritanceRule: .durableCheckpointScoped,
                retentionEligible: true,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.attachmentProjectionCheckpoint.rawValue,
                invalidationKindKeys: [HarnessCheckpointInvalidationKind.attachmentProjection],
                branchInheritanceRule: .durableCheckpointScoped,
                retentionEligible: true,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.attachmentDigestCheckpoint.rawValue,
                invalidationKindKeys: [HarnessCheckpointInvalidationKind.attachmentDigest],
                branchInheritanceRule: .copyVerbatim,
                retentionEligible: true,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.runLifecycleEvent.rawValue,
                invalidationKindKeys: [],
                branchInheritanceRule: .copyVerbatim,
                retentionEligible: false,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.toolAuditLifecycleEvent.rawValue,
                invalidationKindKeys: [],
                branchInheritanceRule: .copyVerbatim,
                retentionEligible: false,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.toolUsageSummaryEvent.rawValue,
                invalidationKindKeys: [],
                branchInheritanceRule: .copyVerbatim,
                retentionEligible: false,
                snapshotSupersessionEligible: false
            ),
            DerivedArtifactContract(
                persistedKind: ConversationEventKind.checkpointInvalidated.rawValue,
                invalidationKindKeys: [],
                branchInheritanceRule: .copyVerbatim,
                retentionEligible: false,
                snapshotSupersessionEligible: false
            ),
        ]
        return Dictionary(uniqueKeysWithValues: contracts.map { ($0.persistedKind, $0) })
    }()

    static func contract(forPersistedKind kind: String) -> DerivedArtifactContract? {
        contractsByKind[kind]
    }

    static func branchInheritanceRule(forPersistedKind kind: String) -> BranchJournalInheritanceRule {
        contractsByKind[kind]?.branchInheritanceRule ?? .omit
    }

    static func invalidationKindKeys(forPersistedKind kind: String) -> [String] {
        contractsByKind[kind]?.invalidationKindKeys ?? []
    }

    static func invalidationFloor(events: [CachedConversationEvent], forPersistedKind kind: String) -> Int {
        let keys = invalidationKindKeys(forPersistedKind: kind)
        guard !keys.isEmpty else { return 0 }
        return ContextCompactionCheckpointSupport.derivedInvalidationFloor(
            events: events,
            invalidatedKindKeys: keys
        )
    }

    static func invalidationFloorMapForRetention(
        events: [CachedConversationEvent]
    ) -> [String: Int] {
        contractsByKind.reduce(into: [:]) { partial, pair in
            guard pair.value.retentionEligible else { return }
            partial[pair.key] = invalidationFloor(events: events, forPersistedKind: pair.key)
        }
    }

    static func snapshotSupersessionFloor(events: [CachedConversationEvent]) -> Int {
        let keys = contractsByKind.values
            .filter { $0.snapshotSupersessionEligible }
            .flatMap(\.invalidationKindKeys)
        guard !keys.isEmpty else { return 0 }
        return ContextCompactionCheckpointSupport.derivedInvalidationFloor(
            events: events,
            invalidatedKindKeys: Array(Set(keys))
        )
    }
}
