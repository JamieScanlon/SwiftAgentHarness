import Foundation

actor ActiveMemoryPreReplyService {
    private let config: MemoryConfiguration
    private var runner: ActiveMemoryPreReplyRunning?
    private let cache = ActiveMemoryRecallCache()

    init(config: MemoryConfiguration) {
        self.config = config
    }

    func setRunner(_ runner: ActiveMemoryPreReplyRunning) {
        self.runner = runner
    }

    // MARK: - Standing lane (query-independent: user + feedback)

    func warmStanding(session: MemorySessionContext) async {
        guard config.activeMemoryStandingEnabled, commonGatesPass(session: session) else { return }
        guard let runner else { return }
        let key = ActiveMemoryRecallCache.Key(conversationID: session.conversationID, lane: .standing, queryFingerprint: nil)
        if await cache.fresh(key, ttlMs: config.activeMemoryStandingTTLMs) != nil { return }
        if await cache.existingInFlight(key) != nil { return }
        let task = Task<String?, Never> { [config] in
            let result = await runner.blockingRecallSummary(
                session: session,
                userQuery: nil,
                lane: .standing,
                timeoutMs: config.activeMemoryStandingBudgetMs,
                maxSummaryChars: config.activeMemoryMaxSummaryChars
            )
            await self.cache.store(key, summary: result)
            return result
        }
        await cache.setInFlight(key, task: task)
    }

    func standingSummary(session: MemorySessionContext) async -> String? {
        guard config.activeMemoryStandingEnabled, commonGatesPass(session: session) else { return nil }
        let key = ActiveMemoryRecallCache.Key(conversationID: session.conversationID, lane: .standing, queryFingerprint: nil)
        if let cached = await cache.fresh(key, ttlMs: config.activeMemoryStandingTTLMs) { return cached }
        // cold: schedule warm and return nil (standing appears on next turn)
        await warmStanding(session: session)
        return nil
    }

    func invalidateStanding(conversationID: UUID) async {
        await cache.invalidate(conversationID: conversationID, lane: .standing)
    }

    func endSession(conversationID: UUID) async {
        await cache.invalidate(conversationID: conversationID, lane: nil)
    }

    // MARK: - Situational lane (query-dependent: project + reference)

    func prefetchSituational(session: MemorySessionContext, userQuery: String) async {
        guard config.activeMemorySituationalEnabled, commonGatesPass(session: session) else { return }
        let trimmed = userQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let runner else { return }
        let fp = queryFingerprint(trimmed)
        let key = ActiveMemoryRecallCache.Key(conversationID: session.conversationID, lane: .situational, queryFingerprint: fp)
        if await cache.fresh(key, ttlMs: config.activeMemorySituationalTTLMs) != nil { return }
        if await cache.existingInFlight(key) != nil { return }
        let task = Task<String?, Never> { [config] in
            let result = await runner.blockingRecallSummary(
                session: session,
                userQuery: trimmed,
                lane: .situational,
                timeoutMs: config.activeMemorySituationalTimeoutMs,
                maxSummaryChars: config.activeMemoryMaxSummaryChars
            )
            await self.cache.store(key, summary: result)
            return result
        }
        await cache.setInFlight(key, task: task)
    }

    func situationalSummary(session: MemorySessionContext, userQuery: String) async -> String? {
        guard config.activeMemorySituationalEnabled, commonGatesPass(session: session) else { return nil }
        let trimmed = userQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let runner else { return nil }
        let fp = queryFingerprint(trimmed)
        let key = ActiveMemoryRecallCache.Key(conversationID: session.conversationID, lane: .situational, queryFingerprint: fp)
        if let cached = await cache.fresh(key, ttlMs: config.activeMemorySituationalTTLMs) { return cached }
        if let inFlight = await cache.existingInFlight(key) {
            return await awaitWithTimeout(timeoutMs: config.activeMemorySituationalTimeoutMs, task: inFlight)
        }
        // cold start: short blocking read
        let result = await runner.blockingRecallSummary(
            session: session,
            userQuery: trimmed,
            lane: .situational,
            timeoutMs: config.activeMemorySituationalTimeoutMs,
            maxSummaryChars: config.activeMemoryMaxSummaryChars
        )
        await cache.store(key, summary: result)
        return result
    }

    // MARK: - Combined entry point

    func recallSummaryIfEnabled(session: MemorySessionContext, userQuery: String) async -> String? {
        guard config.activeMemoryEnabled else { return nil }
        let standing = await standingSummary(session: session)
        let situational = await situationalSummary(session: session, userQuery: userQuery)
        let parts = [standing, situational].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private func commonGatesPass(session: MemorySessionContext) -> Bool {
        guard session.chatType == .direct else { return false }
        if let scope = ConversationScope.current,
           !ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(scope: scope) {
            return false
        }
        return true
    }

    private func queryFingerprint(_ query: String) -> String {
        query.lowercased()
    }

    private func awaitWithTimeout(timeoutMs: Int, task: Task<String?, Never>) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
