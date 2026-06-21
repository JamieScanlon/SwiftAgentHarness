import Foundation

actor ToolRegistryEntryLookup {
    private var byName: [String: ToolRegistryEntry] = [:]

    func install(_ entries: [ToolRegistryEntry]) {
        byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name.lowercased(), $0) })
    }

    func entry(named toolName: String) -> ToolRegistryEntry? {
        byName[toolName.lowercased()]
    }
}
