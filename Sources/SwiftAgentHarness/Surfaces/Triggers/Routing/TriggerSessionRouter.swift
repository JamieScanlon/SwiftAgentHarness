import Foundation

enum TriggerSessionKeyPrefix {
    static func make(source: TriggerSource, routingMode: TriggerRoutingMode, metadata: [String: String]) -> String {
        if let override = metadata["sessionKeyOverride"], !override.isEmpty {
            return override
        }
        switch source {
        case .cron:
            return "cron:\(routingMode.rawValue):\(metadata["cronJobId"] ?? "unknown")"
        case .webhook:
            let route = metadata["routeName"] ?? "unknown"
            if routingMode == .delegated {
                return "webhook:delegated:\(route)"
            }
            return "webhook:\(route)"
        case .channel:
            let channel = metadata["channel"] ?? "unknown"
            let chatId = metadata["chatId"] ?? "unknown"
            if let threadId = metadata["threadId"], !threadId.isEmpty {
                return "channel:\(channel):\(chatId):\(threadId)"
            }
            return "channel:\(channel):\(chatId)"
        case .fileEvent:
            return "file-event:\(metadata["directory"] ?? "events")"
        case .api:
            return "api:\(metadata["routeName"] ?? "unknown")"
        case .delegate:
            return "delegate:\(metadata["delegateId"] ?? "unknown")"
        }
    }
}

struct TriggerSessionRoute: Sendable, Equatable {
    var sessionKey: String
    var conversationID: UUID?
    var routingMode: TriggerRoutingMode
}

struct TriggerSessionRouter: Sendable {
    private let sessionIndex: TriggerSessionIndex

    init(sessionIndex: TriggerSessionIndex) {
        self.sessionIndex = sessionIndex
    }

    func route(_ trigger: HarnessTrigger) async throws -> TriggerSessionRoute {
        let sessionKey = TriggerSessionKeyPrefix.make(
            source: trigger.source,
            routingMode: trigger.routingMode,
            metadata: trigger.sourceMetadata
        )
        switch trigger.routingMode {
        case .isolated:
            let fallbackRaw = trigger.sourceMetadata["parentFallbackCandidates"] ?? ""
            let fallbacks = fallbackRaw.split(separator: "|").map(String.init).filter { !$0.isEmpty }
            let conversationID = try await sessionIndex.resolveWithFallbacks(
                primaryKey: sessionKey,
                fallbackCandidates: fallbacks
            )
            try await sessionIndex.stampTriggerHost(
                conversationID: conversationID,
                trigger: trigger,
                sessionKey: sessionKey
            )
            return TriggerSessionRoute(sessionKey: sessionKey, conversationID: conversationID, routingMode: .isolated)
        case .threaded:
            if let raw = trigger.sourceMetadata["conversationID"], let id = UUID(uuidString: raw) {
                return TriggerSessionRoute(sessionKey: sessionKey, conversationID: id, routingMode: .threaded)
            }
            let conversationID = try await sessionIndex.resolveOrCreateTriggerHost(
                sessionKey: sessionKey,
                trigger: trigger
            )
            return TriggerSessionRoute(sessionKey: sessionKey, conversationID: conversationID, routingMode: .isolated)
        case .delegated:
            let conversationID = try await sessionIndex.resolveOrCreateTriggerHost(
                sessionKey: sessionKey,
                trigger: trigger
            )
            return TriggerSessionRoute(sessionKey: sessionKey, conversationID: conversationID, routingMode: .delegated)
        }
    }
}

actor TriggerSessionIndex {
    private let isolatedSessions: BoundedLRUCache<UUID>
    private let createConversation: @Sendable (String?) async throws -> UUID
    private let resolveConversationByTitle: @Sendable (String) async throws -> UUID?
    private let stampDelegatedHost: @Sendable (UUID, HarnessTrigger, String) async throws -> Void

    init(
        createConversation: @escaping @Sendable (String?) async throws -> UUID,
        resolveConversationByTitle: @escaping @Sendable (String) async throws -> UUID? = { _ in nil },
        stampDelegatedHost: @escaping @Sendable (UUID, HarnessTrigger, String) async throws -> Void = { _, _, _ in },
        maxIsolatedSessionEntries: Int = BoundedLRUCacheDefaults.isolatedSessionMaxEntries
    ) {
        self.createConversation = createConversation
        self.resolveConversationByTitle = resolveConversationByTitle
        self.stampDelegatedHost = stampDelegatedHost
        self.isolatedSessions = BoundedLRUCache(maxEntries: maxIsolatedSessionEntries)
    }

    func resolveOrCreateIsolated(sessionKey: String, trigger: HarnessTrigger) async throws -> UUID {
        try await resolveOrCreateTriggerHost(sessionKey: sessionKey, trigger: trigger)
    }

    func resolveOrCreateTriggerHost(sessionKey: String, trigger: HarnessTrigger) async throws -> UUID {
        let id = try await resolveOrCreate(sessionKey: sessionKey)
        try await stampTriggerHost(conversationID: id, trigger: trigger, sessionKey: sessionKey)
        return id
    }

    func stampTriggerHost(conversationID: UUID, trigger: HarnessTrigger, sessionKey: String) async throws {
        try await stampDelegatedHost(conversationID, trigger, sessionKey)
    }

    func resolveOrCreateDelegatedHost(sessionKey: String, trigger: HarnessTrigger) async throws -> UUID {
        try await resolveOrCreateTriggerHost(sessionKey: sessionKey, trigger: trigger)
    }

    private func resolveOrCreate(sessionKey: String) async throws -> UUID {
        if let existing = await isolatedSessions.value(for: sessionKey) {
            return existing
        }
        let id: UUID
        if let durable = try await resolveConversationByTitle(sessionKey) {
            id = durable
        } else {
            id = try await createConversation(sessionKey)
        }
        await isolatedSessions.insert(key: sessionKey, value: id)
        return id
    }

    func resolveWithFallbacks(primaryKey: String, fallbackCandidates: [String]) async throws -> UUID {
        if let existing = await isolatedSessions.value(for: primaryKey) {
            return existing
        }
        for candidate in fallbackCandidates {
            if let existing = await isolatedSessions.value(for: candidate) {
                await isolatedSessions.insert(key: primaryKey, value: existing)
                return existing
            }
            if let durable = try await resolveConversationByTitle(candidate) {
                await isolatedSessions.insert(key: primaryKey, value: durable)
                await isolatedSessions.insert(key: candidate, value: durable)
                return durable
            }
        }
        return try await resolveOrCreate(sessionKey: primaryKey)
    }

    func reset() async {
        await isolatedSessions.removeAll()
    }
}
