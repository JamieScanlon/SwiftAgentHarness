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

    private static let sharedOutputContract = """
    Output contract (binary):
    - If useful durable memory exists: reply with a concise third-person memory note only \
    (background for the main agent — not a reply to the user, not first-person chat).
    - If nothing useful exists: reply with exactly NONE (bias toward silence). Do not apologize, \
    narrate the search, or say that nothing was found in prose.
    - Do not wrap NONE in other sentences. Do not invent memory.

    Good: User prefers Grafana dashboards over raw Prometheus queries for latency reviews.
    Good: NONE
    Bad: I didn't find anything relevant in memory.
    Bad: No relevant memory was found.
    Bad: Sure — here's what I know about your preferences: …
    """

    private static func standingSystemPrompt() -> String {
        """
        You are a memory recall assistant. Read durable memory files of type 'user' and 'feedback' only.
        Use memory_search and memory_get. Do not write memory or call other tools.
        Prefer silence when the standing profile is empty or not useful for this session.

        \(sharedOutputContract)
        """
    }

    private static func standingUserPrompt() -> String {
        "Recall the user's profile, stable preferences, and feedback patterns from memory. Reply with a memory note or NONE."
    }

    private static func situationalSystemPrompt() -> String {
        """
        You are a memory recall assistant. Search and read durable memory files of type 'project' and 'reference' relevant to the user's query.
        Use memory_search and memory_get only. Do not write memory or call other tools.
        Prefer silence when nothing in memory materially helps this query.

        \(sharedOutputContract)
        """
    }

    private static func situationalUserPrompt(query: String) -> String {
        """
        Recall project and reference memory relevant to this user message (memory note or NONE):
        \(query)
        """
    }
}
