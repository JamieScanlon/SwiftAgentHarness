import Foundation

protocol MemoryCorpusSupplementSearching: Sendable {
    var pluginID: String { get }
    var corpusName: String { get }
    func search(query: String, limit: Int) async -> [MemorySearchHit]
    func get(lookupID: String) async -> String?
}
