import Foundation

enum AttachmentRecencyProjectionPolicy {
    static func naturalDecision(
        for descriptor: ConversationAttachmentDescriptor,
        modelSupportsVision: Bool,
        policy: ContextEngineAttachmentProjectionPolicyInput
    ) -> ConversationAttachmentProjectionDecision {
        let normalizedKind = descriptor.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let byteSize = descriptor.byteSize ?? 0
        let isImage = normalizedKind == "image" || (descriptor.mimeType?.lowercased().hasPrefix("image/") == true)
        let disposition: ConversationAttachmentProjectionDisposition
        let reason: String
        if isImage, !modelSupportsVision {
            disposition = .summarize
            reason = "vision_unsupported"
        } else if byteSize > 0, byteSize <= policy.inlineByteLimit {
            disposition = .inline
            reason = "within_inline_budget"
        } else if byteSize == 0 || byteSize <= policy.summarizeByteLimit {
            disposition = .summarize
            reason = byteSize == 0 ? "unknown_size" : "within_summary_budget"
        } else {
            disposition = .searchOnly
            reason = "over_budget"
        }
        return ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: disposition,
            reason: reason
        )
    }

    static func applyRecencyDemotion(
        decisions: [ConversationAttachmentProjectionDecision],
        catalog: [ConversationAttachmentDescriptor],
        accessIndex: AttachmentAccessIndex,
        recencyPolicy: ContextEngineAttachmentRecencyPolicyInput
    ) -> [ConversationAttachmentProjectionDecision] {
        guard recencyPolicy.enabled else { return decisions }
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        return decisions.map { decision in
            guard let descriptor = catalogByID[decision.attachmentID] else { return decision }
            return applyRecencyDemotion(
                to: decision,
                descriptor: descriptor,
                accessIndex: accessIndex,
                recencyPolicy: recencyPolicy
            )
        }
    }

    static func applyPerKindInlineCaps(
        decisions: [ConversationAttachmentProjectionDecision],
        catalog: [ConversationAttachmentDescriptor],
        accessIndex: AttachmentAccessIndex,
        recencyPolicy: ContextEngineAttachmentRecencyPolicyInput
    ) -> [ConversationAttachmentProjectionDecision] {
        guard recencyPolicy.enabled else { return decisions }
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var output = decisions
        let inlineImageIndices = output.indices.filter { index in
            let decision = output[index]
            guard decision.disposition == .inline,
                  let descriptor = catalogByID[decision.attachmentID] else {
                return false
            }
            return isImageDescriptor(descriptor)
        }
        guard inlineImageIndices.count > recencyPolicy.maxInlineImages else { return output }
        let ranked = inlineImageIndices.sorted { lhs, rhs in
            let leftID = output[lhs].attachmentID
            let rightID = output[rhs].attachmentID
            let leftAccess = accessIndex.lastAccessTurnIndex(for: leftID) ?? -1
            let rightAccess = accessIndex.lastAccessTurnIndex(for: rightID) ?? -1
            if leftAccess != rightAccess { return leftAccess > rightAccess }
            let leftAdded = catalogByID[leftID]?.addedAt ?? .distantPast
            let rightAdded = catalogByID[rightID]?.addedAt ?? .distantPast
            return leftAdded > rightAdded
        }
        let demoteIndices = ranked.dropFirst(recencyPolicy.maxInlineImages)
        for index in demoteIndices {
            var decision = output[index]
            decision.disposition = .summarize
            decision.reason = appendReason(decision.reason, "image_inline_cap")
            output[index] = decision
        }
        return output
    }

    private static func applyRecencyDemotion(
        to decision: ConversationAttachmentProjectionDecision,
        descriptor: ConversationAttachmentDescriptor,
        accessIndex: AttachmentAccessIndex,
        recencyPolicy: ContextEngineAttachmentRecencyPolicyInput
    ) -> ConversationAttachmentProjectionDecision {
        let turnsSinceAccess = accessIndex.turnsSinceAccess(for: descriptor.id)
        if turnsSinceAccess <= recencyPolicy.hotAccessTurns {
            return decision
        }
        var copy = decision
        let inlineThreshold = recencyPolicy.demoteInlineAfterTurns + recencyPolicy.hysteresisTurnMargin
        let digestThreshold = recencyPolicy.demoteDigestAfterTurns + recencyPolicy.hysteresisTurnMargin
        if copy.disposition == .inline, turnsSinceAccess > inlineThreshold {
            copy.disposition = .summarize
            copy.reason = appendReason(copy.reason, "recency_cold")
        } else if copy.disposition == .summarize, turnsSinceAccess > digestThreshold {
            copy.disposition = .searchOnly
            copy.reason = appendReason(copy.reason, "recency_cold")
        }
        return copy
    }

    private static func isImageDescriptor(_ descriptor: ConversationAttachmentDescriptor) -> Bool {
        let normalizedKind = descriptor.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedKind == "image" { return true }
        return descriptor.mimeType?.lowercased().hasPrefix("image/") == true
    }

    private static func appendReason(_ existing: String, _ suffix: String) -> String {
        if existing.isEmpty { return suffix }
        if existing.contains(suffix) { return existing }
        return "\(existing)|\(suffix)"
    }
}
