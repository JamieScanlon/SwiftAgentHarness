import Foundation
import Logging

actor ActiveMemoryPreReplyService {
    private let config: MemoryConfiguration
    private let controlStore: ActiveMemoryControlStore
    private let logger: Logger?
    private var runner: ActiveMemoryPreReplyRunning?
    private let cache = ActiveMemoryRecallCache()

    init(
        config: MemoryConfiguration,
        controlStore: ActiveMemoryControlStore = ActiveMemoryControlStore(),
        logger: Logger? = nil
    ) {
        self.config = config
        self.controlStore = controlStore
        self.logger = logger
    }

    func setRunner(_ runner: ActiveMemoryPreReplyRunning) {
        self.runner = runner
    }

    // MARK: - Standing lane (query-independent: user + feedback)

    func warmStanding(session: MemorySessionContext, sessionEnabled: Bool = true) async {
        guard softGatesPass(sessionEnabled: sessionEnabled),
              config.activeMemoryStandingEnabled,
              commonGatesPass(session: session) else { return }
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

    func standingSummary(session: MemorySessionContext, sessionEnabled: Bool = true) async -> String? {
        guard softGatesPass(sessionEnabled: sessionEnabled),
              config.activeMemoryStandingEnabled,
              commonGatesPass(session: session) else { return nil }
        let key = ActiveMemoryRecallCache.Key(conversationID: session.conversationID, lane: .standing, queryFingerprint: nil)
        if let cached = await cache.fresh(key, ttlMs: config.activeMemoryStandingTTLMs) { return cached }
        // cold: schedule warm and return nil (standing appears on next turn)
        await warmStanding(session: session, sessionEnabled: sessionEnabled)
        return nil
    }

    func invalidateStanding(conversationID: UUID) async {
        await cache.invalidate(conversationID: conversationID, lane: .standing)
    }

    func endSession(conversationID: UUID) async {
        await cache.invalidate(conversationID: conversationID, lane: nil)
    }

    // MARK: - Situational lane (query-dependent: project + reference)

    func prefetchSituational(
        session: MemorySessionContext,
        userQuery: String,
        sessionEnabled: Bool = true
    ) async {
        guard softGatesPass(sessionEnabled: sessionEnabled),
              config.activeMemorySituationalEnabled,
              commonGatesPass(session: session) else { return }
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

    func situationalSummary(
        session: MemorySessionContext,
        userQuery: String,
        sessionEnabled: Bool = true
    ) async -> String? {
        guard softGatesPass(sessionEnabled: sessionEnabled),
              config.activeMemorySituationalEnabled,
              commonGatesPass(session: session) else { return nil }
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

    func recallSummaryIfEnabled(
        session: MemorySessionContext,
        userQuery: String,
        sessionEnabled: Bool = true
    ) async -> String? {
        await recallOutcomeIfEnabled(
            session: session,
            userQuery: userQuery,
            sessionEnabled: sessionEnabled
        ).note
    }

    func recallOutcomeIfEnabled(
        session: MemorySessionContext,
        userQuery: String,
        sessionEnabled: Bool = true
    ) async -> ActiveMemoryRecallOutcome {
        let queryMode = config.activeMemoryQueryMode
        let started = ContinuousClock.now

        if let disabled = softGateFailure(sessionEnabled: sessionEnabled) {
            logDone(conversationID: session.conversationID, diagnostics: disabled.diagnostics)
            return disabled
        }
        if session.chatType != .direct {
            let outcome = ActiveMemoryRecallOutcome.skipped(reason: "chatType", queryMode: queryMode)
            logDone(conversationID: session.conversationID, diagnostics: outcome.diagnostics)
            return outcome
        }
        if let scope = ConversationScope.current,
           !ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(scope: scope) {
            let outcome = ActiveMemoryRecallOutcome.skipped(reason: "lineage", queryMode: queryMode)
            logDone(conversationID: session.conversationID, diagnostics: outcome.diagnostics)
            return outcome
        }

        logStart(conversationID: session.conversationID)
        let standing = await standingSummary(session: session, sessionEnabled: sessionEnabled)
        let situational = await situationalSummary(
            session: session,
            userQuery: userQuery,
            sessionEnabled: sessionEnabled
        )
        let parts = [standing, situational].compactMap { $0 }.filter { !$0.isEmpty }
        let note = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        let elapsedMs = elapsedMilliseconds(since: started)
        let diagnostics: ActiveMemoryTurnDiagnostics
        if let note {
            diagnostics = ActiveMemoryTurnDiagnostics(
                status: .ok,
                elapsedMs: elapsedMs,
                queryMode: queryMode,
                summaryChars: note.count,
                note: note,
                skipReason: nil
            )
        } else {
            diagnostics = ActiveMemoryTurnDiagnostics(
                status: .none,
                elapsedMs: elapsedMs,
                queryMode: queryMode,
                summaryChars: 0,
                note: nil,
                skipReason: nil
            )
        }
        logDone(conversationID: session.conversationID, diagnostics: diagnostics)
        return ActiveMemoryRecallOutcome(note: note, diagnostics: diagnostics)
    }

    // MARK: - Helpers

    private func softGatesPass(sessionEnabled: Bool) -> Bool {
        softGateFailure(sessionEnabled: sessionEnabled) == nil
    }

    private func softGateFailure(sessionEnabled: Bool) -> ActiveMemoryRecallOutcome? {
        let queryMode = config.activeMemoryQueryMode
        guard config.activeMemoryEnabled else {
            return .disabled(reason: "config", queryMode: queryMode)
        }
        guard controlStore.isEnabled() else {
            return .disabled(reason: "global", queryMode: queryMode)
        }
        guard sessionEnabled else {
            return .disabled(reason: "session", queryMode: queryMode)
        }
        return nil
    }

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

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        let ms = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        return Int(max(0, ms))
    }

    private func logStart(conversationID: UUID) {
        guard config.activeMemoryLogging else { return }
        logger?.debug(
            "active-memory: start conversation=\(conversationID.uuidString) queryMode=\(config.activeMemoryQueryMode.rawValue)"
        )
    }

    private func logDone(conversationID: UUID, diagnostics: ActiveMemoryTurnDiagnostics) {
        guard config.activeMemoryLogging else { return }
        let reason = diagnostics.skipReason.map { " reason=\($0)" } ?? ""
        logger?.debug(
            "active-memory: done conversation=\(conversationID.uuidString) status=\(diagnostics.status.rawValue) elapsedMs=\(diagnostics.elapsedMs) queryMode=\(diagnostics.queryMode.rawValue)\(reason)"
        )
    }
}
