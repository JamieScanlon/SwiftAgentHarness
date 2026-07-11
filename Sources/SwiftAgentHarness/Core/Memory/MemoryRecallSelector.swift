import Foundation

protocol MemoryRecallSelecting: Sendable {
    func selectRelevantFiles(request: MemoryRecallRequest) async -> [String]
}

struct HeuristicMemoryRecallSelector: MemoryRecallSelecting {
    func selectRelevantFiles(request: MemoryRecallRequest) async -> [String] {
        let queryTokens = tokenSet(request.userQuery)
        guard !queryTokens.isEmpty else { return [] }
        var scored: [(String, Int)] = []
        for entry in request.manifestEntries {
            let headerTokens = tokenSet(
                "\(entry.name) \(entry.description) \(entry.memoryType.rawValue) \(entry.tierScope.rawValue)"
            )
            let overlap = queryTokens.intersection(headerTokens).count
            let score = overlap * 2
            if score > 0 { scored.append((entry.selectionKey, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
    }

    private func tokenSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
}

struct MemoryRecallSelector: MemoryRecallSelecting {
    let heuristic: HeuristicMemoryRecallSelector
    let llmSelector: MemoryLLMRecallSelecting?

    init(llmSelector: MemoryLLMRecallSelecting? = nil) {
        self.heuristic = HeuristicMemoryRecallSelector()
        self.llmSelector = llmSelector
    }

    func selectRelevantFiles(request: MemoryRecallRequest) async -> [String] {
        if request.manifestEntries.count > 30, let llm = llmSelector {
            if let selected = try? await llm.selectRelevantFiles(request: request), !selected.isEmpty {
                return Array(selected.prefix(5))
            }
        }
        return await heuristic.selectRelevantFiles(request: request)
    }
}

protocol MemoryLLMRecallSelecting: Sendable {
    func selectRelevantFiles(request: MemoryRecallRequest) async throws -> [String]
}

struct NoOpMemoryLLMRecallSelector: MemoryLLMRecallSelecting {
    func selectRelevantFiles(request: MemoryRecallRequest) async throws -> [String] {
        _ = request
        return []
    }
}
