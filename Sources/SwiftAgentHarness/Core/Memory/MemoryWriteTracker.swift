import Foundation

actor MemoryWriteTracker: MemoryWriteObserving {
    private var mainAgentWritesByConversation: [UUID: Set<String>] = [:]
    private var auxiliaryWritesByConversation: [UUID: Set<String>] = [:]

    func recordMainAgentWrite(path: String, conversationID: UUID) {
        insert(path: path, into: &mainAgentWritesByConversation, conversationID: conversationID)
    }

    func recordAuxiliaryWrite(path: String, conversationID: UUID) {
        insert(path: path, into: &auxiliaryWritesByConversation, conversationID: conversationID)
    }

    func hadMainAgentWrites(conversationID: UUID) async -> Bool {
        !(mainAgentWritesByConversation[conversationID]?.isEmpty ?? true)
    }

    func hadWrites(conversationID: UUID) async -> Bool {
        await hadMainAgentWrites(conversationID: conversationID)
            || !(auxiliaryWritesByConversation[conversationID]?.isEmpty ?? true)
    }

    func mainAgentWrittenPaths(conversationID: UUID) async -> [String] {
        Array(mainAgentWritesByConversation[conversationID] ?? []).sorted()
    }

    func auxiliaryWrittenPaths(conversationID: UUID) async -> [String] {
        Array(auxiliaryWritesByConversation[conversationID] ?? []).sorted()
    }

    func writtenPaths(conversationID: UUID) async -> [String] {
        let main = mainAgentWritesByConversation[conversationID] ?? []
        let auxiliary = auxiliaryWritesByConversation[conversationID] ?? []
        return Array(main.union(auxiliary)).sorted()
    }

    func resetTurn(conversationID: UUID) async {
        mainAgentWritesByConversation[conversationID] = []
        auxiliaryWritesByConversation[conversationID] = []
    }

    private func insert(path: String, into store: inout [UUID: Set<String>], conversationID: UUID) {
        var set = store[conversationID] ?? []
        set.insert((path as NSString).standardizingPath)
        store[conversationID] = set
    }
}
