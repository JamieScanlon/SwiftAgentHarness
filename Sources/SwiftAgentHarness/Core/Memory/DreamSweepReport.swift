import Foundation

struct DreamThresholdSnapshot: Codable, Sendable, Equatable {
    let minScore: Double
    let minRecallCount: Int
    let minUniqueQueries: Int

    init(minScore: Double, minRecallCount: Int, minUniqueQueries: Int) {
        self.minScore = minScore
        self.minRecallCount = minRecallCount
        self.minUniqueQueries = minUniqueQueries
    }

    init(config: MemoryConfiguration) {
        self.minScore = config.dreamingMinScore
        self.minRecallCount = config.dreamingMinRecallCount
        self.minUniqueQueries = config.dreamingMinUniqueQueries
    }
}

enum DreamCandidateOutcome: String, Codable, Sendable, Equatable {
    case staged
    case rem
    case promoted
    case rejected
}

enum DreamRejectReason: String, Codable, Sendable, Equatable {
    case belowMinScore
    case belowRecallCount
    case belowUniqueQueries
    case emptySnippet
    case contamination
    case dailyMissing
    case staleSnippet
    case liveSnippetEmpty
    case recallSourceSkipped
    case notInTopN
}

struct DreamCandidateReport: Codable, Sendable, Equatable {
    let filename: String
    let signal: Double
    let recallCount: Int
    let uniqueQueryCount: Int
    let snippetPreview: String
    let outcome: String
    let rejectReason: String?
    let promotedTopic: String?

    init(
        filename: String,
        signal: Double,
        recallCount: Int,
        uniqueQueryCount: Int,
        snippetPreview: String,
        outcome: DreamCandidateOutcome,
        rejectReason: DreamRejectReason? = nil,
        promotedTopic: String? = nil
    ) {
        self.filename = filename
        self.signal = signal
        self.recallCount = recallCount
        self.uniqueQueryCount = uniqueQueryCount
        self.snippetPreview = String(snippetPreview.prefix(120))
            .replacingOccurrences(of: "\n", with: " ")
        self.outcome = outcome.rawValue
        self.rejectReason = rejectReason?.rawValue
        self.promotedTopic = promotedTopic
    }

    static func from(
        candidate: DreamCandidate,
        outcome: DreamCandidateOutcome,
        rejectReason: DreamRejectReason? = nil,
        promotedTopic: String? = nil
    ) -> DreamCandidateReport {
        DreamCandidateReport(
            filename: candidate.filename,
            signal: candidate.signal,
            recallCount: candidate.recallCount,
            uniqueQueryCount: candidate.uniqueQueryCount,
            snippetPreview: candidate.snippet,
            outcome: outcome,
            rejectReason: rejectReason,
            promotedTopic: promotedTopic
        )
    }
}

struct DreamSweepReport: Codable, Sendable, Equatable {
    static let lastSweepFilename = "last-sweep.json"
    static let diaryFilename = "DREAMS.md"

    let runID: String
    let completedAt: String
    let thresholds: DreamThresholdSnapshot
    let light: [DreamCandidateReport]
    let rem: [DreamCandidateReport]
    let deepPromoted: [DreamCandidateReport]
    let deepRejected: [DreamCandidateReport]

    var topRejectReason: String? {
        var counts: [String: Int] = [:]
        for row in deepRejected {
            guard let reason = row.rejectReason else { continue }
            counts[reason, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}

struct DreamSweepReportStore: Sendable {
    let memoryDirectory: URL

    var dreamsDirectory: URL {
        memoryDirectory.appendingPathComponent(".dreams", isDirectory: true)
    }

    var lastSweepURL: URL {
        dreamsDirectory.appendingPathComponent(DreamSweepReport.lastSweepFilename)
    }

    var diaryURL: URL {
        memoryDirectory.appendingPathComponent(DreamSweepReport.diaryFilename)
    }

    func write(_ report: DreamSweepReport) throws {
        try FileManager.default.createDirectory(at: dreamsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try MemoryFileLock.atomicWrite(data: data, to: lastSweepURL)
    }

    func read() throws -> DreamSweepReport? {
        guard FileManager.default.fileExists(atPath: lastSweepURL.path) else { return nil }
        let data = try Data(contentsOf: lastSweepURL)
        return try JSONDecoder().decode(DreamSweepReport.self, from: data)
    }

    func appendDiary(for report: DreamSweepReport) throws {
        let section = DreamingReviewFormatter.diarySection(report: report)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: diaryURL, encoding: .utf8)) ?? ""
        let next: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next = "# DREAMS\n\nHuman-readable dreaming diary (not a promotion target).\n\n" + section
        } else {
            next = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + section
        }
        try MemoryFileLock.atomicWrite(text: next + "\n", to: diaryURL)
    }
}

enum DreamingReviewFormatter: Sendable {
    static func explain(report: DreamSweepReport?, memoryDirectory: URL) -> String {
        guard let report else {
            return "No sweep report yet. Run a dreaming sweep first (nightly cron or memory dreaming status after a sweep)."
        }
        var lines: [String] = [
            "Dreaming explain (runID=\(report.runID))",
            "Completed: \(report.completedAt)",
            "Thresholds: minScore=\(formatScore(report.thresholds.minScore)) minRecallCount=\(report.thresholds.minRecallCount) minUniqueQueries=\(report.thresholds.minUniqueQueries)",
            "Light staged: \(report.light.count)  REM: \(report.rem.count)  Promoted: \(report.deepPromoted.count)  Rejected: \(report.deepRejected.count)",
            "",
        ]
        if report.deepPromoted.isEmpty {
            lines.append("Promoted: none")
        } else {
            lines.append("Promoted:")
            for row in report.deepPromoted {
                let topic = row.promotedTopic.map { " → \($0)" } ?? ""
                lines.append(
                    "- \(row.filename)\(topic) signal=\(formatScore(row.signal)) recalls=\(row.recallCount)/\(row.uniqueQueryCount) \"\(row.snippetPreview)\""
                )
            }
        }
        lines.append("")
        if report.deepRejected.isEmpty {
            lines.append("Rejected: none")
        } else {
            lines.append("Rejected (top \(min(10, report.deepRejected.count))):")
            for row in report.deepRejected.prefix(10) {
                let reason = row.rejectReason ?? "unknown"
                lines.append(
                    "- \(row.filename) reason=\(reason) signal=\(formatScore(row.signal)) recalls=\(row.recallCount)/\(row.uniqueQueryCount)"
                )
            }
        }
        lines.append("")
        lines.append("Report: \(memoryDirectory.appendingPathComponent(".dreams/\(DreamSweepReport.lastSweepFilename)").path)")
        lines.append("Diary: \(memoryDirectory.appendingPathComponent(DreamSweepReport.diaryFilename).path)")
        return lines.joined(separator: "\n")
    }

    static func diarySection(report: DreamSweepReport) -> String {
        var rejectCounts: [String: Int] = [:]
        for row in report.deepRejected {
            let key = row.rejectReason ?? "unknown"
            rejectCounts[key, default: 0] += 1
        }
        let rejectSummary: String
        if rejectCounts.isEmpty {
            rejectSummary = "none"
        } else {
            rejectSummary = rejectCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
        }
        let promotedList: String
        if report.deepPromoted.isEmpty {
            promotedList = "none"
        } else {
            promotedList = report.deepPromoted.map { row in
                if let topic = row.promotedTopic {
                    return "\(row.filename) → \(topic)"
                }
                return row.filename
            }.joined(separator: ", ")
        }
        let topSignals = report.light.prefix(3).map {
            "\($0.filename)=\(formatScore($0.signal))"
        }.joined(separator: ", ")
        return """
        ## Sweep \(report.completedAt) (`\(report.runID)`)

        - Thresholds: minScore=\(formatScore(report.thresholds.minScore)), minRecallCount=\(report.thresholds.minRecallCount), minUniqueQueries=\(report.thresholds.minUniqueQueries)
        - Light staged: \(report.light.count)\(topSignals.isEmpty ? "" : " (top: \(topSignals))")
        - Deep promoted: \(promotedList)
        - Rejects: \(rejectSummary)
        """
    }

    static func statusExtras(
        config: MemoryConfiguration,
        memoryDirectory: URL?
    ) -> [String] {
        var lines = [
            "Thresholds: minScore=\(formatScore(config.dreamingMinScore)) minRecallCount=\(config.dreamingMinRecallCount) minUniqueQueries=\(config.dreamingMinUniqueQueries)",
        ]
        guard let memoryDirectory else { return lines }

        let ledger = DreamPromotionLedger(memoryDirectory: memoryDirectory)
        if let marker = ledger.readLastDeepMarker() {
            lines.append(
                "Last deep: runID=\(marker.runID.isEmpty ? "(legacy)" : marker.runID) promoted=\(marker.promoted.count) sourceDailies=\(marker.sourceDailies.count)"
            )
        } else {
            lines.append("Last deep: none for this workspace")
        }

        let store = DreamSweepReportStore(memoryDirectory: memoryDirectory)
        if let report = try? store.read() {
            let topReject = report.topRejectReason.map { " topReject=\($0)" } ?? ""
            lines.append(
                "Last sweep: \(report.completedAt) staged=\(report.light.count) promoted=\(report.deepPromoted.count) rejected=\(report.deepRejected.count)\(topReject)"
            )
        } else {
            lines.append("Last sweep: none")
        }
        lines.append("Diary: \(store.diaryURL.path)")
        lines.append("Sweep report: \(store.lastSweepURL.path)")
        return lines
    }

    private static func formatScore(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
