import Foundation

struct MemorySearchCoordinator: Sendable {
    let activeCorpusName: String
    let backendSearch: @Sendable (String, Int) async -> [MemorySearchHit]
    let backendGet: @Sendable (String) async -> String?
    let supplementRegistry: MemoryCorpusSupplementRegistry

    func search(query: String, corpus: String?, limit: Int) async -> [MemorySearchHit] {
        let normalized = corpus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == nil || normalized?.isEmpty == true || normalized == activeCorpusName {
            return await backendSearch(query, limit)
        }
        if normalized == MemorySearchCorpusNames.all {
            var merged = await backendSearch(query, limit)
            for supplement in await supplementRegistry.allSupplements() {
                let extra = await supplement.search(query: query, limit: limit)
                merged.append(contentsOf: extra)
            }
            return Array(merged.sorted { $0.score > $1.score }.prefix(limit))
        }
        guard let supplement = await supplementRegistry.supplement(named: normalized!) else {
            return []
        }
        return await supplement.search(query: query, limit: limit)
    }

    func get(lookupID: String, corpus: String?) async -> String? {
        let normalized = corpus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == nil || normalized?.isEmpty == true || normalized == activeCorpusName {
            return await backendGet(lookupID)
        }
        guard let supplement = await supplementRegistry.supplement(named: normalized!) else {
            return nil
        }
        return await supplement.get(lookupID: lookupID)
    }

    func availableCorpora() async -> [String] {
        var names = [activeCorpusName, MemorySearchCorpusNames.all]
        names.append(contentsOf: await supplementRegistry.corpusNames())
        return names
    }
}
