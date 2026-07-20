import Foundation

enum SkillWorkshopServiceError: Error, Equatable {
    case disabled
    case emptyReason
    case invalidChange(String)
    case proposalNotPending(UUID)
    case proposalQuarantined(UUID)
    case applyBlockedByScan
}

struct SkillWorkshopSuggestResult: Sendable, Equatable {
    let proposal: SkillWorkshopProposal
    let deduplicated: Bool
}

actor SkillWorkshopService {
    private let config: SkillWorkshopConfiguration
    private let workspaceKey: String
    private let skillsRoot: URL
    private let store: SkillWorkshopProposalStore
    private let writer: SkillWorkshopWriter
    private let onApplied: @Sendable (UUID?) async -> Void

    init(
        config: SkillWorkshopConfiguration,
        workspaceKey: String,
        skillsRoot: URL,
        store: SkillWorkshopProposalStore,
        writer: SkillWorkshopWriter? = nil,
        onApplied: @escaping @Sendable (UUID?) async -> Void = { _ in }
    ) {
        self.config = config
        self.workspaceKey = workspaceKey
        self.skillsRoot = skillsRoot
        self.store = store
        self.writer = writer ?? SkillWorkshopWriter(skillsRoot: skillsRoot)
        self.onApplied = onApplied
    }

    func suggest(
        reason: String,
        change: SkillWorkshopChange,
        sessionID: UUID?
    ) async throws -> SkillWorkshopSuggestResult {
        guard config.enabled else { throw SkillWorkshopServiceError.disabled }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else { throw SkillWorkshopServiceError.emptyReason }
        try validateChange(change)

        let normalizedName = try SkillWorkshopSkillNameNormalizer.normalize(change.skillName)
        let normalizedChange = SkillWorkshopChange(
            action: change.action,
            skillName: normalizedName,
            title: change.title,
            description: change.description,
            body: change.body,
            sectionName: change.sectionName,
            oldText: change.oldText
        )

        if let duplicate = try await store.findDuplicatePendingOrQuarantined(change: normalizedChange) {
            return SkillWorkshopSuggestResult(proposal: duplicate, deduplicated: true)
        }

        let preview = try writer.previewContent(for: normalizedChange, normalizedName: normalizedName)
        let scan = SkillWorkshopContentScanner.scan(preview + "\n" + trimmedReason)
        let status: SkillWorkshopProposalStatus = scan.hasCritical ? .quarantined : .pending
        let proposal = SkillWorkshopProposal(
            workspaceKey: workspaceKey,
            sessionID: sessionID,
            reason: trimmedReason,
            status: status,
            change: normalizedChange,
            scanFindings: scan.allFindings,
            quarantineReason: scan.hasCritical ? "Critical security findings detected" : nil
        )
        let stored = try await store.insert(proposal)
        return SkillWorkshopSuggestResult(proposal: stored, deduplicated: false)
    }

    func apply(proposalID: UUID) async throws -> SkillWorkshopProposal {
        guard config.enabled else { throw SkillWorkshopServiceError.disabled }
        let proposal = try await store.inspect(id: proposalID)
        guard proposal.status == .pending else {
            if proposal.status == .quarantined {
                throw SkillWorkshopServiceError.proposalQuarantined(proposalID)
            }
            throw SkillWorkshopServiceError.proposalNotPending(proposalID)
        }

        let normalizedName = try SkillWorkshopSkillNameNormalizer.normalize(proposal.change.skillName)
        let preview = try writer.previewContent(for: proposal.change, normalizedName: normalizedName)
        let scan = SkillWorkshopContentScanner.scan(preview)
        guard !scan.hasCritical else {
            _ = try await store.markQuarantined(
                id: proposalID,
                reason: "Critical findings on apply",
                findings: scan.allFindings
            )
            throw SkillWorkshopServiceError.applyBlockedByScan
        }

        _ = try writer.apply(change: proposal.change)
        let applied = try await store.markApplied(id: proposalID)
        await onApplied(proposal.sessionID)
        return applied
    }

    func reject(proposalID: UUID) async throws -> SkillWorkshopProposal {
        guard config.enabled else { throw SkillWorkshopServiceError.disabled }
        let proposal = try await store.inspect(id: proposalID)
        guard proposal.status == .pending else {
            throw SkillWorkshopServiceError.proposalNotPending(proposalID)
        }
        return try await store.markRejected(id: proposalID)
    }

    func list(status: SkillWorkshopProposalStatus?) async throws -> [SkillWorkshopProposal] {
        try await store.list(status: status)
    }

    func inspect(proposalID: UUID) async throws -> SkillWorkshopProposal {
        try await store.inspect(id: proposalID)
    }

    func statusCounts() async throws -> [SkillWorkshopProposalStatus: Int] {
        try await store.statusCounts()
    }

    private func validateChange(_ change: SkillWorkshopChange) throws {
        guard !change.skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillWorkshopServiceError.invalidChange("skill_name required")
        }
        guard !change.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillWorkshopServiceError.invalidChange("description required")
        }
        guard !change.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillWorkshopServiceError.invalidChange("body required")
        }
        switch change.action {
        case .append:
            break
        case .replace:
            guard let oldText = change.oldText, !oldText.isEmpty else {
                throw SkillWorkshopServiceError.invalidChange("old_text required for replace")
            }
        case .create:
            break
        }
    }
}
