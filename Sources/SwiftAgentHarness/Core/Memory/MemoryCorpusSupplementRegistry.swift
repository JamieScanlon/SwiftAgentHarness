import Foundation

actor MemoryCorpusSupplementRegistry {
    private var supplementsByPluginID: [String: any MemoryCorpusSupplementSearching] = [:]

    func register(_ supplement: any MemoryCorpusSupplementSearching) {
        supplementsByPluginID[supplement.pluginID] = supplement
    }

    func supplement(named corpus: String) -> (any MemoryCorpusSupplementSearching)? {
        supplementsByPluginID.values.first { $0.corpusName == corpus }
    }

    func allSupplements() -> [any MemoryCorpusSupplementSearching] {
        Array(supplementsByPluginID.values)
    }

    func corpusNames() -> [String] {
        supplementsByPluginID.values.map(\.corpusName).sorted()
    }
}
