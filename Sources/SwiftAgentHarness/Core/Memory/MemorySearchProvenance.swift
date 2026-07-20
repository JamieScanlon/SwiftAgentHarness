import Foundation

enum MemorySearchCorpusNames {
    static let builtinFile = "builtin-file"
    static let all = "all"
}

struct MemorySearchLineRange: Sendable, Equatable, Codable {
    let startLine: Int
    let endLine: Int
}

struct MemorySearchProvenance: Sendable, Equatable {
    let corpus: String
    let provenanceLabel: String
    let sourceType: String
    let sourcePath: String
    let citation: String
    let updatedAt: Date?
    let lineRange: MemorySearchLineRange?

    static func citationToken(
        corpus: String,
        sourcePath: String,
        lineRange: MemorySearchLineRange?
    ) -> String {
        if let lineRange {
            return "[\(corpus):\(sourcePath) L\(lineRange.startLine)-\(lineRange.endLine)]"
        }
        return "[\(corpus):\(sourcePath)]"
    }
}

struct MemorySearchHit: Sendable, Equatable {
    let lookupID: String
    let score: Double
    let snippet: String
    let provenance: MemorySearchProvenance

    var filename: String { lookupID }

    init(lookupID: String, score: Double, snippet: String, provenance: MemorySearchProvenance) {
        self.lookupID = lookupID
        self.score = score
        self.snippet = snippet
        self.provenance = provenance
    }

    func withScore(_ score: Double) -> MemorySearchHit {
        MemorySearchHit(lookupID: lookupID, score: score, snippet: snippet, provenance: provenance)
    }

    static func fixture(lookupID: String, score: Double, snippet: String, corpus: String = MemorySearchCorpusNames.builtinFile) -> MemorySearchHit {
        MemorySearchHit(
            lookupID: lookupID,
            score: score,
            snippet: snippet,
            provenance: MemorySearchProvenance(
                corpus: corpus,
                provenanceLabel: "Agent memory (topic)",
                sourceType: "memory-topic",
                sourcePath: lookupID,
                citation: MemorySearchProvenance.citationToken(corpus: corpus, sourcePath: lookupID, lineRange: nil),
                updatedAt: nil,
                lineRange: nil
            )
        )
    }
}

enum MemorySearchHitRenderer {
    static func render(_ hit: MemorySearchHit) -> String {
        let updated = hit.provenance.updatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        var parts = [
            "corpus=\(hit.provenance.corpus)",
            "cite=\(hit.provenance.citation)",
            "score=\(hit.score)",
            "updated=\(updated)",
            "lookup=\(hit.lookupID)",
        ]
        if let range = hit.provenance.lineRange {
            parts.append("lines=\(range.startLine)-\(range.endLine)")
        }
        return parts.joined(separator: " ") + ": \(hit.snippet)"
    }

    static func renderList(_ hits: [MemorySearchHit]) -> String {
        hits.map(render).joined(separator: "\n")
    }
}

enum MemorySearchLineRangeCalculator {
    static func range(for query: String, in body: String) -> MemorySearchLineRange? {
        let queryTokens = tokenSet(query)
        guard !queryTokens.isEmpty else { return nil }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var matching: [Int] = []
        for (index, line) in lines.enumerated() {
            let lineTokens = tokenSet(String(line))
            if !lineTokens.intersection(queryTokens).isEmpty {
                matching.append(index + 1)
            }
        }
        guard let first = matching.first, let last = matching.last else { return nil }
        return MemorySearchLineRange(startLine: first, endLine: last)
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
}

struct MemorySearchToolDependencies: Sendable {
    let search: @Sendable (String, String?, Int) async -> [MemorySearchHit]
    let get: @Sendable (String, String?) async -> String?
    let activeCorpusName: @Sendable () async -> String
    let availableCorpora: @Sendable () async -> [String]
}
