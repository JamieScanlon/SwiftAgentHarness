import CryptoKit
import Foundation

enum SkillWorkshopProposalStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case pending
    case applied
    case rejected
    case quarantined
}

enum SkillWorkshopProposalSource: String, Sendable, Codable, Equatable {
    case tool
}

enum SkillWorkshopChangeAction: String, Sendable, Codable, Equatable {
    case create
    case append
    case replace
}

struct SkillWorkshopScanFinding: Sendable, Codable, Equatable {
    let ruleID: String
    let severity: String
    let message: String
}

struct SkillWorkshopChange: Sendable, Codable, Equatable {
    let action: SkillWorkshopChangeAction
    let skillName: String
    let title: String
    let description: String
    let body: String
    let sectionName: String?
    let oldText: String?

    func fingerprint() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct SkillWorkshopProposal: Sendable, Codable, Equatable, Identifiable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    let workspaceKey: String
    let sessionID: UUID?
    let reason: String
    let source: SkillWorkshopProposalSource
    var status: SkillWorkshopProposalStatus
    let change: SkillWorkshopChange
    var scanFindings: [SkillWorkshopScanFinding]
    var quarantineReason: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        workspaceKey: String,
        sessionID: UUID?,
        reason: String,
        source: SkillWorkshopProposalSource = .tool,
        status: SkillWorkshopProposalStatus,
        change: SkillWorkshopChange,
        scanFindings: [SkillWorkshopScanFinding] = [],
        quarantineReason: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workspaceKey = workspaceKey
        self.sessionID = sessionID
        self.reason = reason
        self.source = source
        self.status = status
        self.change = change
        self.scanFindings = scanFindings
        self.quarantineReason = quarantineReason
    }
}

enum SkillWorkshopStoreError: Error, Equatable {
    case proposalNotFound(UUID)
    case invalidStatusTransition
    case duplicatePending
}
