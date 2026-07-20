import Foundation

enum AttachmentRungCoordinator {
    static let attachmentBreakEventReasons: Set<CacheBreakEventReason> = [
        .compactionCommit,
        .cacheExpiry,
        .modelChange,
        .providerChange,
        .sessionStart,
        .manualCompaction,
    ]

    static func coordinate(
        catalog: [ConversationAttachmentDescriptor],
        targetDecisions: [ConversationAttachmentProjectionDecision],
        priorDecisions: [ConversationAttachmentProjectionDecision]?,
        naturalDecisions: [ConversationAttachmentProjectionDecision],
        accessIndex: AttachmentAccessIndex,
        pendingBreakEvents: Set<CacheBreakEventReason>,
        recencyPolicy: ContextEngineAttachmentRecencyPolicyInput
    ) -> (effective: [ConversationAttachmentProjectionDecision], target: [ConversationAttachmentProjectionDecision]) {
        let priorByID = Dictionary(uniqueKeysWithValues: (priorDecisions ?? []).map { ($0.attachmentID, $0) })
        let naturalByID = Dictionary(uniqueKeysWithValues: naturalDecisions.map { ($0.attachmentID, $0) })
        let shouldApplyBreak = !pendingBreakEvents.intersection(attachmentBreakEventReasons).isEmpty
        var effective = targetDecisions

        if pendingBreakEvents.contains(.compactionCommit), recencyPolicy.enabled {
            effective = applyCompactionHotSetPromotion(
                effective: effective,
                catalog: catalog,
                naturalByID: naturalByID,
                accessIndex: accessIndex,
                recencyPolicy: recencyPolicy
            )
        }

        if shouldApplyBreak {
            return (effective: effective, target: targetDecisions)
        }

        let held = targetDecisions.map { target in
            guard let prior = priorByID[target.attachmentID],
                  prior.disposition != target.disposition else {
                return target
            }
            var copy = prior
            copy.reason = appendReason(copy.reason, "hysteresis_hold")
            return copy
        }
        return (effective: held, target: targetDecisions)
    }

    private static func applyCompactionHotSetPromotion(
        effective: [ConversationAttachmentProjectionDecision],
        catalog: [ConversationAttachmentDescriptor],
        naturalByID: [UUID: ConversationAttachmentProjectionDecision],
        accessIndex: AttachmentAccessIndex,
        recencyPolicy: ContextEngineAttachmentRecencyPolicyInput
    ) -> [ConversationAttachmentProjectionDecision] {
        let promoteCount = max(0, recencyPolicy.promoteHotSetOnCompaction)
        guard promoteCount > 0 else { return effective }
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let rankedIDs = catalog.map(\.id).sorted { lhs, rhs in
            let leftAccess = accessIndex.lastAccessTurnIndex(for: lhs) ?? -1
            let rightAccess = accessIndex.lastAccessTurnIndex(for: rhs) ?? -1
            if leftAccess != rightAccess { return leftAccess > rightAccess }
            let leftAdded = catalogByID[lhs]?.addedAt ?? .distantPast
            let rightAdded = catalogByID[rhs]?.addedAt ?? .distantPast
            return leftAdded > rightAdded
        }
        let promoteIDs = Set(rankedIDs.prefix(promoteCount))
        return effective.map { decision in
            guard promoteIDs.contains(decision.attachmentID),
                  let natural = naturalByID[decision.attachmentID] else {
                return decision
            }
            var copy = decision
            let promoted = promoteOneRung(copy.disposition)
            copy.disposition = minDisposition(promoted, ceiling: natural.disposition)
            if copy.disposition != decision.disposition {
                copy.reason = appendReason(copy.reason, "compaction_hot_set_promotion")
            }
            return copy
        }
    }

    private static func promoteOneRung(
        _ disposition: ConversationAttachmentProjectionDisposition
    ) -> ConversationAttachmentProjectionDisposition {
        switch disposition {
        case .searchOnly: return .summarize
        case .summarize: return .inline
        case .inline: return .inline
        }
    }

    private static func minDisposition(
        _ lhs: ConversationAttachmentProjectionDisposition,
        ceiling: ConversationAttachmentProjectionDisposition
    ) -> ConversationAttachmentProjectionDisposition {
        rank(lhs) >= rank(ceiling) ? lhs : ceiling
    }

    private static func rank(_ disposition: ConversationAttachmentProjectionDisposition) -> Int {
        switch disposition {
        case .inline: return 0
        case .summarize: return 1
        case .searchOnly: return 2
        }
    }

    private static func appendReason(_ existing: String, _ suffix: String) -> String {
        if existing.isEmpty { return suffix }
        if existing.contains(suffix) { return existing }
        return "\(existing)|\(suffix)"
    }
}
