import Foundation
import Logging

actor DreamingConsolidationScheduler {
    private let config: MemoryConfiguration
    private let logger: Logger?

    init(config: MemoryConfiguration, logger: Logger? = nil) {
        self.config = config
        self.logger = logger
    }

    func runSweep(memoryDirectory: URL, rollback: Bool = false) async throws {
        let dreamsDir = memoryDirectory.appendingPathComponent(".dreams", isDirectory: true)
        try FileManager.default.createDirectory(at: dreamsDir, withIntermediateDirectories: true)
        if rollback {
            try rollbackBackfill(dreamsDir: dreamsDir)
            return
        }
        let candidates = try stageLightPhase(memoryDirectory: memoryDirectory, dreamsDir: dreamsDir)
        let themes = remPhase(candidates: candidates)
        try await deepPhase(
            memoryDirectory: memoryDirectory,
            dreamsDir: dreamsDir,
            candidates: themes
        )
    }

    private func stageLightPhase(memoryDirectory: URL, dreamsDir: URL) throws -> [DreamCandidate] {
        let manifest = MemoryManifestScanner.scanDirectory(memoryDirectory)
        return manifest.map { entry in
            DreamCandidate(
                filename: entry.filename,
                signal: 0.24 + 0.15,
                snippet: entry.description
            )
        }
    }

    private func remPhase(candidates: [DreamCandidate]) -> [DreamCandidate] {
        candidates.map { c in
            DreamCandidate(filename: c.filename, signal: c.signal + 0.10, snippet: c.snippet)
        }
    }

    private func deepPhase(
        memoryDirectory: URL,
        dreamsDir: URL,
        candidates: [DreamCandidate]
    ) async throws {
        let store = AgentMemoryStore(memoryDirectory: memoryDirectory)
        let ranked = candidates.filter { $0.signal >= config.dreamingMinScore }.sorted { $0.signal > $1.signal }.prefix(3)
        guard !ranked.isEmpty else { return }
        var index = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        for candidate in ranked {
            let line = "- [\(candidate.filename)](\(candidate.filename)) — \(candidate.snippet)"
            if !index.contains(candidate.filename) {
                index += (index.isEmpty ? "" : "\n") + line
            }
        }
        if let capFired = try store.writeIndex(content: index) {
            logger?.warning("[Dreaming] MEMORY.md truncated at write: \(capFired)")
        }
        logger?.info("[Dreaming] promoted \(ranked.count) candidate(s) to MEMORY.md")
        let marker = dreamsDir.appendingPathComponent("last-deep.json")
        let payload = ["promoted": ranked.map(\.filename)]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: marker)
    }

    private func rollbackBackfill(dreamsDir: URL) throws {
        let marker = dreamsDir.appendingPathComponent("last-deep.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }
}

private struct DreamCandidate: Sendable {
    let filename: String
    let signal: Double
    let snippet: String
}
