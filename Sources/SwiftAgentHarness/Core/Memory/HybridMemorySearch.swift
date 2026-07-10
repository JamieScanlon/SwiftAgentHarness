import Foundation

struct HybridMemorySearch: Sendable {
    func search(query: String, memoryDirectory: URL, limit: Int = 10) async -> [MemorySearchHit] {
        let queryTokens = tokenSet(query)
        var hits: [MemorySearchHit] = []
        hits.append(contentsOf: topicHits(query: query, queryTokens: queryTokens, memoryDirectory: memoryDirectory))
        hits.append(contentsOf: dailyHits(query: query, queryTokens: queryTokens, memoryDirectory: memoryDirectory))
        if hasEmbeddingAPIKey() {
            hits = hits.map { $0.withScore($0.score * 1.2) }
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private func topicHits(query: String, queryTokens: Set<String>, memoryDirectory: URL) -> [MemorySearchHit] {
        let manifest = MemoryManifestScanner.scanDirectory(memoryDirectory)
        var hits: [MemorySearchHit] = []
        for entry in manifest {
            let fileURL = memoryDirectory.appendingPathComponent(entry.filename)
            let body = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let header = "\(entry.name) \(entry.description) \(entry.memoryType.rawValue)"
            let headerScore = Double(tokenSet(header).intersection(queryTokens).count) * 2.0
            let bodyScore = Double(tokenSet(body).intersection(queryTokens).count)
            let score = headerScore + bodyScore
            guard score > 0 else { continue }
            let lineRange = MemorySearchLineRangeCalculator.range(for: query, in: body)
            let citation = MemorySearchProvenance.citationToken(
                corpus: MemorySearchCorpusNames.builtinFile,
                sourcePath: entry.filename,
                lineRange: lineRange
            )
            hits.append(
                MemorySearchHit(
                    lookupID: entry.filename,
                    score: score,
                    snippet: String(body.prefix(300)),
                    provenance: MemorySearchProvenance(
                        corpus: MemorySearchCorpusNames.builtinFile,
                        provenanceLabel: "Agent memory (topic)",
                        sourceType: "memory-topic",
                        sourcePath: entry.filename,
                        citation: citation,
                        updatedAt: entry.updatedAt,
                        lineRange: lineRange
                    )
                )
            )
        }
        return hits
    }

    private func dailyHits(query: String, queryTokens: Set<String>, memoryDirectory: URL) -> [MemorySearchHit] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: memoryDirectory.path) else { return [] }
        var hits: [MemorySearchHit] = []
        for filename in files where AgentMemoryStore.isDailyFilename(filename) {
            let fileURL = memoryDirectory.appendingPathComponent(filename)
            let body = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let score = Double(tokenSet(body).intersection(queryTokens).count)
            guard score > 0 else { continue }
            let updatedAt = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let lineRange = MemorySearchLineRangeCalculator.range(for: query, in: body)
            let citation = MemorySearchProvenance.citationToken(
                corpus: MemorySearchCorpusNames.builtinFile,
                sourcePath: filename,
                lineRange: lineRange
            )
            hits.append(
                MemorySearchHit(
                    lookupID: filename,
                    score: score,
                    snippet: String(body.prefix(300)),
                    provenance: MemorySearchProvenance(
                        corpus: MemorySearchCorpusNames.builtinFile,
                        provenanceLabel: "Agent memory (daily)",
                        sourceType: "memory-daily",
                        sourcePath: filename,
                        citation: citation,
                        updatedAt: updatedAt,
                        lineRange: lineRange
                    )
                )
            )
        }
        return hits
    }

    private func tokenSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }

    private func hasEmbeddingAPIKey() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return ["OPENAI_API_KEY", "GEMINI_API_KEY", "VOYAGE_API_KEY", "MISTRAL_API_KEY"]
            .contains { key in
                guard let value = env[key] else { return false }
                return !value.isEmpty
            }
    }
}
