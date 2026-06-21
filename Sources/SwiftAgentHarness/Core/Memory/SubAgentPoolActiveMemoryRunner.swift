import Foundation
import Logging

struct SubAgentPoolActiveMemoryRunner: ActiveMemoryPreReplyRunning {
    private let spawnPort: MemorySubAgentSpawnPort
    private let config: MemoryConfiguration
    private let logger: Logger?

    init(spawnPort: MemorySubAgentSpawnPort, config: MemoryConfiguration, logger: Logger? = nil) {
        self.spawnPort = spawnPort
        self.config = config
        self.logger = logger
    }

    func blockingRecallSummary(
        session: MemorySessionContext,
        userQuery: String?,
        lane: RecallLane,
        timeoutMs: Int,
        maxSummaryChars: Int
    ) async -> String? {
        guard config.activeMemoryEnabled else { return nil }
        guard session.chatType == .direct else { return nil }
        if let scope = ConversationScope.current,
           !ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(scope: scope) {
            return nil
        }
        if lane == .situational {
            guard let query = userQuery, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }
        logger?.debug("[ActiveMemory] blocking recall lane=\(lane.rawValue) conversation=\(session.conversationID.uuidString)")
        return await spawnPort.spawnBlockingRecall(
            session.conversationID,
            userQuery,
            lane,
            timeoutMs,
            maxSummaryChars
        )
    }
}

enum ActiveMemoryPreReplyPrompts {
    static func systemPrompt() -> String { situationalSystemPrompt() }
    static func userPrompt(query: String) -> String { situationalUserPrompt(query: query) }

    static func prompts(for lane: RecallLane, query: String?) -> (system: String, user: String) {
        switch lane {
        case .standing:
            return (standingSystemPrompt(), standingUserPrompt())
        case .situational:
            return (situationalSystemPrompt(), situationalUserPrompt(query: query ?? ""))
        }
    }

    private static func standingSystemPrompt() -> String {
        """
You are a memory recall assistant. Read durable memory files of type 'user' and 'feedback' only.
Use memory_search and memory_get. Do not write memory or call other tools.
Return a concise factual summary of the user's stable profile, preferences, and feedback patterns.
"""
    }

    private static func standingUserPrompt() -> String {
        "Recall the user's profile, stable preferences, and feedback patterns from memory."
    }

    private static func situationalSystemPrompt() -> String {
        """
You are a memory recall assistant. Search and read durable memory files of type 'project' and 'reference' relevant to the user's query.
Use memory_search and memory_get only. Do not write memory or call other tools.
Return a concise factual summary of what you found. If nothing relevant exists, say so briefly.
"""
    }

    private static func situationalUserPrompt(query: String) -> String {
        """
Recall project and reference memory relevant to this user message:
\(query)
"""
    }
}
