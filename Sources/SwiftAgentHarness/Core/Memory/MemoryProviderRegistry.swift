import Foundation

enum MemoryProviderRegistryError: Error, Equatable {
    case externalProviderAlreadyRegistered
}

actor MemoryProviderRegistry {
    private let builtin: any MemoryProviding
    private var external: (any MemoryProviding)?
    private var externalID: String?

    init(builtin: any MemoryProviding) {
        self.builtin = builtin
    }

    func registerExternal(id: String, provider: any MemoryProviding) throws {
        if external != nil { throw MemoryProviderRegistryError.externalProviderAlreadyRegistered }
        external = provider
        externalID = id
    }

    func activeProviders() -> [any MemoryProviding] {
        if let external { return [builtin, external] }
        return [builtin]
    }

    func externalProviderID() -> String? { externalID }

    func shutdownAll() async {
        await builtin.shutdown()
        if let external { await external.shutdown() }
    }

    func endSessionAll(messages: [String]) async {
        await builtin.onSessionEnd(messages: messages)
        if let external { await external.onSessionEnd(messages: messages) }
    }
}

struct BuiltinFileMemoryProvider: MemoryProviding {
    func initialize(sessionID: UUID, context: MemorySessionContext) async throws {
        _ = sessionID
        try AgentMemoryStore(memoryDirectory: context.memoryDirectory).ensureLayout()
    }

    func systemPromptBlock() async -> String { "" }

    func prefetch(query: String) async -> String? {
        _ = query
        return nil
    }

    func queuePrefetch(query: String) async {
        _ = query
    }

    func syncTurn(userContent: String, assistantContent: String) async {
        _ = userContent
        _ = assistantContent
    }

    func onPreCompress(messages: [String]) async -> String {
        _ = messages
        return ""
    }

    func onSessionEnd(messages: [String]) async {
        _ = messages
    }

    func shutdown() async {}
}
