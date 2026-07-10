import Foundation

actor SkillWorkshopProposalStore {
    static let proposalsFilename = "proposals.jsonl"

    private let workspaceKey: String
    private let config: SkillWorkshopConfiguration
    private let stateRoot: URL
    private let fileManager: FileManager
    private var proposals: [SkillWorkshopProposal] = []

    init(
        workspaceKey: String,
        config: SkillWorkshopConfiguration,
        stateRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.workspaceKey = workspaceKey
        self.config = config
        self.stateRoot = stateRoot ?? MemoryConfigHome.resolve(fileManager: fileManager)
        self.fileManager = fileManager
    }

    var storeDirectory: URL {
        stateRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(workspaceKey, isDirectory: true)
            .appendingPathComponent("skill-workshop", isDirectory: true)
    }

    var proposalsURL: URL {
        storeDirectory.appendingPathComponent(Self.proposalsFilename)
    }

    func loadIfNeeded() throws {
        guard proposals.isEmpty else { return }
        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: proposalsURL.path) else { return }
        let data = try String(contentsOf: proposalsURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = try? decoder.decode(SkillWorkshopProposal.self, from: Data(line.utf8)) else { continue }
            proposals.append(row)
        }
    }

    func statusCounts() async throws -> [SkillWorkshopProposalStatus: Int] {
        try loadIfNeeded()
        var counts = Dictionary(uniqueKeysWithValues: SkillWorkshopProposalStatus.allCases.map { ($0, 0) })
        for proposal in proposals {
            counts[proposal.status, default: 0] += 1
        }
        return counts
    }

    func list(status: SkillWorkshopProposalStatus?) async throws -> [SkillWorkshopProposal] {
        try loadIfNeeded()
        let sorted = proposals.sorted { $0.updatedAt > $1.updatedAt }
        guard let status else { return sorted }
        return sorted.filter { $0.status == status }
    }

    func inspect(id: UUID) async throws -> SkillWorkshopProposal {
        try loadIfNeeded()
        guard let proposal = proposals.first(where: { $0.id == id }) else {
            throw SkillWorkshopStoreError.proposalNotFound(id)
        }
        return proposal
    }

    func findDuplicatePendingOrQuarantined(change: SkillWorkshopChange) async throws -> SkillWorkshopProposal? {
        try loadIfNeeded()
        let fingerprint = change.fingerprint()
        return proposals.first { proposal in
            (proposal.status == .pending || proposal.status == .quarantined)
                && proposal.change.skillName == change.skillName
                && proposal.change.fingerprint() == fingerprint
        }
    }

    @discardableResult
    func insert(_ proposal: SkillWorkshopProposal) async throws -> SkillWorkshopProposal {
        try loadIfNeeded()
        if let duplicate = try await findDuplicatePendingOrQuarantined(change: proposal.change) {
            return duplicate
        }
        proposals.append(proposal)
        try enforceCap()
        try persist()
        return proposal
    }

    func markApplied(id: UUID) async throws -> SkillWorkshopProposal {
        try updateStatus(id: id, to: .applied)
    }

    func markRejected(id: UUID) async throws -> SkillWorkshopProposal {
        try updateStatus(id: id, to: .rejected)
    }

    func markQuarantined(id: UUID, reason: String, findings: [SkillWorkshopScanFinding]) async throws -> SkillWorkshopProposal {
        try loadIfNeeded()
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw SkillWorkshopStoreError.proposalNotFound(id)
        }
        proposals[index].status = .quarantined
        proposals[index].quarantineReason = reason
        proposals[index].scanFindings = findings
        proposals[index].updatedAt = Date()
        try persist()
        return proposals[index]
    }

    private func updateStatus(id: UUID, to status: SkillWorkshopProposalStatus) throws -> SkillWorkshopProposal {
        try loadIfNeeded()
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw SkillWorkshopStoreError.proposalNotFound(id)
        }
        proposals[index].status = status
        proposals[index].updatedAt = Date()
        try persist()
        return proposals[index]
    }

    private func enforceCap() throws {
        guard proposals.count > config.maxProposalsPerWorkspace else { return }
        let overflow = proposals.count - config.maxProposalsPerWorkspace
        let removable = proposals
            .enumerated()
            .filter { $0.element.status != .applied }
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .prefix(overflow)
            .map(\.offset)
            .sorted(by: >)
        for index in removable {
            proposals.remove(at: index)
        }
    }

    private func persist() throws {
        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try proposals.map { proposal -> String in
            let data = try encoder.encode(proposal)
            guard let line = String(data: data, encoding: .utf8) else {
                throw SkillWorkshopWriterError.encodingFailed
            }
            return line
        }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try MemoryFileLock.atomicWrite(text: text, to: proposalsURL, fileManager: fileManager)
    }
}
