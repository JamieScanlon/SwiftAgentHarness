import Foundation

struct MemorySearchHit: Sendable, Equatable {
    let filename: String
    let score: Double
    let snippet: String
}

struct HybridMemorySearch: Sendable {
    func search(query: String, memoryDirectory: URL, limit: Int = 10) async -> [MemorySearchHit] {
        let manifest = MemoryManifestScanner.scanDirectory(memoryDirectory)
        let queryTokens = tokenSet(query)
        var hits: [MemorySearchHit] = []
        for entry in manifest {
            let header = "\(entry.name) \(entry.description) \(entry.memoryType.rawValue)"
            let bodyPreview = (try? String(contentsOf: memoryDirectory.appendingPathComponent(entry.filename), encoding: .utf8))?
                .prefix(500) ?? ""
            let headerScore = Double(tokenSet(header).intersection(queryTokens).count) * 2.0
            let bodyScore = Double(tokenSet(String(bodyPreview)).intersection(queryTokens).count)
            let score = headerScore + bodyScore
            guard score > 0 else { continue }
            hits.append(MemorySearchHit(filename: entry.filename, score: score, snippet: String(bodyPreview.prefix(300))))
        }
        if hasEmbeddingAPIKey() {
            for i in hits.indices {
                hits[i] = MemorySearchHit(
                    filename: hits[i].filename,
                    score: hits[i].score * 1.2,
                    snippet: hits[i].snippet
                )
            }
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
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
