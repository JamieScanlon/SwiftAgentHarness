import Foundation

struct DreamPromotionRecord: Sendable, Codable, Equatable {
    static let originDreamingDeep = "dreaming-deep"

    let runID: String
    let promotedAt: String
    let topicFilename: String
    let sourceDaily: String?
    let indexLine: String
    let createdNewFile: Bool
    let origin: String
}

struct DreamLastDeepMarker: Sendable, Codable, Equatable {
    var runID: String
    var promoted: [String]
    var sourceDailies: [String]
}

struct DreamPromotionLedger: Sendable {
    static let promotionsFilename = "promotions.jsonl"
    static let lastDeepFilename = DreamRecallStore.lastDeepFilename

    let memoryDirectory: URL

    var dreamsDirectory: URL {
        memoryDirectory.appendingPathComponent(".dreams", isDirectory: true)
    }

    var promotionsURL: URL {
        dreamsDirectory.appendingPathComponent(Self.promotionsFilename)
    }

    var lastDeepURL: URL {
        dreamsDirectory.appendingPathComponent(Self.lastDeepFilename)
    }

    func ensureDreamsDirectory() throws {
        try FileManager.default.createDirectory(at: dreamsDirectory, withIntermediateDirectories: true)
    }

    func append(_ records: [DreamPromotionRecord]) throws {
        guard !records.isEmpty else { return }
        try ensureDreamsDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let pathKey = memoryDirectory.standardizedFileURL.path
        let processLock = DreamRecallPathLocks.lock(for: pathKey)
        processLock.lock()
        defer { processLock.unlock() }
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory) {
            var chunk = ""
            for record in records {
                let data = try encoder.encode(record)
                guard let line = String(data: data, encoding: .utf8) else { continue }
                chunk += line
                chunk += "\n"
            }
            let existing = (try? String(contentsOf: promotionsURL, encoding: .utf8)) ?? ""
            try MemoryFileLock.atomicWrite(text: existing + chunk, to: promotionsURL)
        }
    }

    func loadRecords() throws -> [DreamPromotionRecord] {
        try ensureDreamsDirectory()
        guard FileManager.default.fileExists(atPath: promotionsURL.path) else { return [] }
        let text = try String(contentsOf: promotionsURL, encoding: .utf8)
        let decoder = JSONDecoder()
        var records: [DreamPromotionRecord] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let record = try? decoder.decode(DreamPromotionRecord.self, from: data) {
                records.append(record)
            }
        }
        return records
    }

    func records(forRunID runID: String) throws -> [DreamPromotionRecord] {
        try loadRecords().filter { $0.runID == runID }
    }

    func writeLastDeepMarker(_ marker: DreamLastDeepMarker) throws {
        try ensureDreamsDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(marker)
        try MemoryFileLock.atomicWrite(data: data, to: lastDeepURL)
    }

    func readLastDeepMarker() -> DreamLastDeepMarker? {
        guard FileManager.default.fileExists(atPath: lastDeepURL.path),
              let data = try? Data(contentsOf: lastDeepURL)
        else {
            return nil
        }
        if let marker = try? JSONDecoder().decode(DreamLastDeepMarker.self, from: data) {
            return marker
        }
        // Legacy: { "promoted": [...] }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let promoted = json["promoted"] as? [String]
        {
            return DreamLastDeepMarker(runID: "", promoted: promoted, sourceDailies: [])
        }
        return nil
    }

    func clearLastDeepMarker() throws {
        if FileManager.default.fileExists(atPath: lastDeepURL.path) {
            try FileManager.default.removeItem(at: lastDeepURL)
        }
    }

    /// Filenames used for consolidation boost — prefer source dailies when present.
    func previouslyPromotedSourceFilenames() -> Set<String> {
        guard let marker = readLastDeepMarker() else { return [] }
        if !marker.sourceDailies.isEmpty {
            return Set(marker.sourceDailies)
        }
        return Set(marker.promoted)
    }

    static func topicHasDreamingOrigin(_ content: String) -> Bool {
        guard content.hasPrefix("---") else { return false }
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else { return false }
        for line in parts[1].components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("origin:") {
                let value = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
                return value == DreamPromotionRecord.originDreamingDeep
            }
        }
        return false
    }
}
