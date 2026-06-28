import Foundation

/// Bounds global concurrent LLM calls (Phase 5). Fairness across conversations can extend this actor later.
///
/// Honors ``ModelRequestPriority`` via two FIFO wait queues (foreground / background). When a slot opens
/// the foreground queue is served first, except when the head of the background queue has been waiting
/// longer than ``backgroundStarvationGrace`` — in which case it is promoted ahead of foreground waiters
/// so background traffic (e.g. compaction, summarization) cannot starve under sustained foreground load.
public actor ModelCallScheduler: ModelCallScheduling {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let enqueuedAt: Date
        let reservation: ModelCallReservation
    }

    private struct TokenBucketState {
        var requestTokens: Double
        var tokenTokens: Double
        var lastRefillAt: Date
    }

    /// Output of ``selectNextWaiter(foregroundCount:oldestBackgroundEnqueuedAt:now:starvationGrace:)``.
    enum WaiterChoice: Equatable {
        case foreground
        case background
    }

    private let maxConcurrent: Int
    private let backgroundStarvationGrace: TimeInterval
    private let policy: ModelCallSchedulerPolicy
    private var inFlight: Int = 0
    private var pendingResumes: Int = 0
    private var inFlightByModel: [UUID: Int] = [:]
    private var inFlightByCredential: [String: Int] = [:]
    private var tokenBucketsByScopeKey: [String: TokenBucketState] = [:]
    private var foregroundWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []
    private var lastServedForegroundConversation: String?
    private var lastServedBackgroundConversation: String?
    private var refillTickerTask: Task<Void, Never>?
    private let onPoolHealthChange: (@Sendable (PoolHealthPayload) async -> Void)?
    /// Notified after every per-model in-flight delta (acquire/release). Drives ``ModelStatePayload/inFlightCount``.
    private let onModelInFlightChange: (@Sendable (UUID, Int, Int?) async -> Void)?

    public init(
        maxConcurrent: Int = 8,
        backgroundStarvationGrace: TimeInterval = 5.0,
        policy: ModelCallSchedulerPolicy = ModelCallSchedulerPolicy(),
        onPoolHealthChange: (@Sendable (PoolHealthPayload) async -> Void)? = nil,
        onModelInFlightChange: (@Sendable (UUID, Int, Int?) async -> Void)? = nil
    ) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.backgroundStarvationGrace = max(0, backgroundStarvationGrace)
        self.policy = policy
        self.onPoolHealthChange = onPoolHealthChange
        self.onModelInFlightChange = onModelInFlightChange
    }

    /// Snapshot for ``pool/health`` wire topic.
    ///
    /// `PoolHealthPayload.errorRate` stays `nil` until error-rate aggregation lands; `budgetRemaining`
    /// is enriched at the composition root from ``BudgetReporting/poolBudgetRemainingUSD()`` rather
    /// than here (the scheduler intentionally has no dependency on accounting). `queueDepth` is the
    /// combined size of the foreground and background wait queues, and ``PoolHealthPayload/queueDepthByPriority``
    /// surfaces the per-priority breakdown (sums to `queueDepth`).
    public func poolHealthSnapshot() -> PoolHealthPayload {
        PoolHealthPayload(
            queueDepth: foregroundWaiters.count + backgroundWaiters.count,
            inFlight: inFlight,
            maxConcurrent: maxConcurrent,
            updatedAt: Date(),
            queueDepthByPriority: PoolHealthQueueDepth(
                foreground: foregroundWaiters.count,
                background: backgroundWaiters.count
            )
        )
    }

    public func inFlightCount(for modelID: UUID) -> Int {
        inFlightByModel[modelID] ?? 0
    }

    /// Effective concurrent-call cap for `modelID` (per-model override, policy default, then global `maxConcurrent`).
    public func concurrencyLimit(for modelID: UUID) -> Int {
        effectiveModelCap(for: modelID) ?? maxConcurrent
    }

    /// Wires scheduler in-flight notifications into ``ModelInvocationCoordinator`` for state payload publishing.
    public static func wiredForInvocationTracking(
        coordinator: ModelInvocationCoordinator,
        maxConcurrent: Int = 8,
        backgroundStarvationGrace: TimeInterval = 5.0,
        policy: ModelCallSchedulerPolicy = ModelCallSchedulerPolicy(),
        onPoolHealthChange: (@Sendable (PoolHealthPayload) async -> Void)? = nil
    ) -> ModelCallScheduler {
        ModelCallScheduler(
            maxConcurrent: maxConcurrent,
            backgroundStarvationGrace: backgroundStarvationGrace,
            policy: policy,
            onPoolHealthChange: onPoolHealthChange,
            onModelInFlightChange: { modelID, count, concurrencyLimit in
                await coordinator.recordInFlight(
                    modelID: modelID,
                    count: count,
                    concurrencyLimit: concurrencyLimit
                )
            }
        )
    }

    /// When both arguments are nil, returns a scheduler wired to a fresh coordinator.
    public static func resolveInvocationTrackingPair(
        scheduler: (any ModelCallScheduling)?,
        coordinator: (any ModelInvocationLifecycleTracking)?
    ) -> (any ModelCallScheduling, any ModelInvocationLifecycleTracking) {
        if let scheduler, let coordinator {
            return (scheduler, coordinator)
        }
        if scheduler == nil, coordinator == nil {
            let coordinator = ModelInvocationCoordinator()
            let scheduler = wiredForInvocationTracking(coordinator: coordinator)
            return (scheduler, coordinator)
        }
        if let scheduler {
            return (scheduler, coordinator ?? ModelInvocationCoordinator())
        }
        return (ModelCallScheduler(), coordinator!)
    }

    public func acquire(for modelID: UUID, priority: ModelRequestPriority) async {
        _ = await acquire(reservation: ModelCallReservation(modelID: modelID, priority: priority))
    }

    public func acquire(reservation: ModelCallReservation) async -> ModelCallAcquisition {
        while true {
            let now = Date()
            if canAdmit(reservation: reservation, now: now, consumeRateTokens: true) {
                inFlight += 1
                let nextModelCount = (inFlightByModel[reservation.modelID] ?? 0) + 1
                inFlightByModel[reservation.modelID] = nextModelCount
                if let credentialKey = normalizedCredentialKey(from: reservation.credentialKey) {
                    inFlightByCredential[credentialKey] = (inFlightByCredential[credentialKey] ?? 0) + 1
                }
                await emitPoolHealth()
                await emitModelInFlight(modelID: reservation.modelID, count: nextModelCount)
                return ModelCallAcquisition(
                    modelID: reservation.modelID,
                    credentialKey: normalizedCredentialKey(from: reservation.credentialKey),
                    reservedRequestUnits: policy.requestBucketPerMinute == nil ? 0 : 1,
                    reservedTokenUnits: reservedTokenUnits(for: reservation)
                )
            }
            await withCheckedContinuation { continuation in
                let waiter = Waiter(continuation: continuation, enqueuedAt: now, reservation: reservation)
                switch reservation.priority {
                case .foreground: foregroundWaiters.append(waiter)
                case .background: backgroundWaiters.append(waiter)
                }
                // Start refill wakeups as soon as a blocked waiter is queued; otherwise token-bucket
                // callers can deadlock waiting for a refill that never gets scheduled.
                startRefillTickerIfNeeded()
            }
            pendingResumes = max(0, pendingResumes - 1)
        }
    }

    public func release(for modelID: UUID) async {
        await release(acquisition: ModelCallAcquisition(modelID: modelID))
    }

    public func release(acquisition: ModelCallAcquisition) async {
        inFlight = max(0, inFlight - 1)
        let modelID = acquisition.modelID
        let prior = inFlightByModel[modelID] ?? 0
        let next = max(0, prior - 1)
        if next == 0 {
            inFlightByModel.removeValue(forKey: modelID)
        } else {
            inFlightByModel[modelID] = next
        }

        if let credentialKey = normalizedCredentialKey(from: acquisition.credentialKey) {
            let priorCredential = inFlightByCredential[credentialKey] ?? 0
            let nextCredential = max(0, priorCredential - 1)
            if nextCredential == 0 {
                inFlightByCredential.removeValue(forKey: credentialKey)
            } else {
                inFlightByCredential[credentialKey] = nextCredential
            }
        }

        resumeWaitersIfPossible()
        await emitPoolHealth()
        await emitModelInFlight(modelID: modelID, count: next)
    }

    private func emitPoolHealth() async {
        guard let onPoolHealthChange else { return }
        await onPoolHealthChange(poolHealthSnapshot())
    }

    private func emitModelInFlight(modelID: UUID, count: Int) async {
        guard let onModelInFlightChange else { return }
        await onModelInFlightChange(modelID, count, concurrencyLimit(for: modelID))
    }

    private func resumeWaitersIfPossible() {
        while effectiveInFlight() < maxConcurrent {
            guard resumeOneWaiterIfPossible() else { break }
        }
        stopRefillTickerIfIdle()
    }

    @discardableResult
    private func resumeOneWaiterIfPossible() -> Bool {
        guard effectiveInFlight() < maxConcurrent else { return false }
        let now = Date()
        let choice = Self.selectNextWaiter(
            foregroundCount: foregroundWaiters.count,
            oldestBackgroundEnqueuedAt: backgroundWaiters.first?.enqueuedAt,
            now: now,
            starvationGrace: backgroundStarvationGrace
        )
        let primary: WaiterChoice?
        let secondary: WaiterChoice?
        switch choice {
        case .foreground:
            primary = .foreground
            secondary = .background
        case .background:
            primary = .background
            secondary = .foreground
        case nil:
            primary = nil
            secondary = nil
        }

        if let primary, let waiter = popNextAdmissibleWaiter(from: primary, now: now) {
            pendingResumes += 1
            waiter.continuation.resume()
            return true
        }
        if let secondary, let waiter = popNextAdmissibleWaiter(from: secondary, now: now) {
            pendingResumes += 1
            waiter.continuation.resume()
            return true
        }
        return false
    }

    private func popNextAdmissibleWaiter(from choice: WaiterChoice, now: Date) -> Waiter? {
        switch choice {
        case .foreground:
            return popNextAdmissibleWaiter(
                from: &foregroundWaiters,
                lastServedConversation: &lastServedForegroundConversation,
                now: now
            )
        case .background:
            return popNextAdmissibleWaiter(
                from: &backgroundWaiters,
                lastServedConversation: &lastServedBackgroundConversation,
                now: now
            )
        }
    }

    private func popNextAdmissibleWaiter(
        from queue: inout [Waiter],
        lastServedConversation: inout String?,
        now: Date
    ) -> Waiter? {
        guard !queue.isEmpty else { return nil }
        switch policy.fairness {
        case .fifo:
            guard let idx = queue.firstIndex(where: { canAdmit(reservation: $0.reservation, now: now, consumeRateTokens: false) }) else {
                return nil
            }
            let waiter = queue.remove(at: idx)
            lastServedConversation = conversationFairnessKey(for: waiter.reservation.conversationID)
            return waiter
        case .roundRobinByConversation:
            return popRoundRobinAdmissibleWaiter(
                from: &queue,
                lastServedConversation: &lastServedConversation,
                now: now
            )
        }
    }

    private func popRoundRobinAdmissibleWaiter(
        from queue: inout [Waiter],
        lastServedConversation: inout String?,
        now: Date
    ) -> Waiter? {
        guard !queue.isEmpty else { return nil }
        var orderedConversationKeys: [String] = []
        for waiter in queue {
            let key = conversationFairnessKey(for: waiter.reservation.conversationID)
            if !orderedConversationKeys.contains(key) {
                orderedConversationKeys.append(key)
            }
        }
        guard !orderedConversationKeys.isEmpty else { return nil }

        let startIndex: Int = {
            guard let lastServedConversation,
                  let idx = orderedConversationKeys.firstIndex(of: lastServedConversation)
            else { return 0 }
            return (idx + 1) % orderedConversationKeys.count
        }()

        for offset in 0..<orderedConversationKeys.count {
            let key = orderedConversationKeys[(startIndex + offset) % orderedConversationKeys.count]
            if let idx = queue.firstIndex(where: {
                conversationFairnessKey(for: $0.reservation.conversationID) == key
                    && canAdmit(reservation: $0.reservation, now: now, consumeRateTokens: false)
            }) {
                let waiter = queue.remove(at: idx)
                lastServedConversation = key
                return waiter
            }
        }

        guard let idx = queue.firstIndex(where: { canAdmit(reservation: $0.reservation, now: now, consumeRateTokens: false) }) else {
            return nil
        }
        let waiter = queue.remove(at: idx)
        lastServedConversation = conversationFairnessKey(for: waiter.reservation.conversationID)
        return waiter
    }

    private func canAdmit(
        reservation: ModelCallReservation,
        now: Date,
        consumeRateTokens: Bool
    ) -> Bool {
        guard effectiveInFlight() < maxConcurrent else { return false }

        if let cap = effectiveModelCap(for: reservation.modelID),
           (inFlightByModel[reservation.modelID] ?? 0) >= cap {
            return false
        }

        let credentialKey = normalizedCredentialKey(from: reservation.credentialKey)
        if let credentialKey,
           let cap = effectiveCredentialCap(for: credentialKey),
           (inFlightByCredential[credentialKey] ?? 0) >= cap {
            return false
        }

        return canConsumeRateTokens(
            reservation: reservation,
            normalizedCredentialKey: credentialKey,
            now: now,
            consume: consumeRateTokens
        )
    }

    private func canConsumeRateTokens(
        reservation: ModelCallReservation,
        normalizedCredentialKey: String?,
        now: Date,
        consume: Bool
    ) -> Bool {
        guard policy.requestBucketPerMinute != nil || policy.tokenBucketPerMinute != nil else {
            return true
        }
        let scopeKey = bucketScopeKey(for: normalizedCredentialKey)
        var bucket = tokenBucketsByScopeKey[scopeKey] ?? TokenBucketState(
            requestTokens: Double(policy.requestBucketPerMinute ?? 0),
            tokenTokens: Double(policy.tokenBucketPerMinute ?? 0),
            lastRefillAt: now
        )
        refill(bucket: &bucket, now: now)

        let requiredRequestTokens = policy.requestBucketPerMinute == nil ? 0.0 : 1.0
        let requiredTokenTokens = policy.tokenBucketPerMinute == nil ? 0.0 : Double(reservedTokenUnits(for: reservation))
        let admissible = bucket.requestTokens >= requiredRequestTokens && bucket.tokenTokens >= requiredTokenTokens
        if admissible, consume {
            if requiredRequestTokens > 0 {
                bucket.requestTokens -= requiredRequestTokens
            }
            if requiredTokenTokens > 0 {
                bucket.tokenTokens -= requiredTokenTokens
            }
        }
        tokenBucketsByScopeKey[scopeKey] = bucket
        return admissible
    }

    private func refill(bucket: inout TokenBucketState, now: Date) {
        let elapsed = max(0, now.timeIntervalSince(bucket.lastRefillAt))
        bucket.lastRefillAt = now
        if let requestPerMinute = policy.requestBucketPerMinute {
            let add = elapsed * (Double(requestPerMinute) / 60.0)
            bucket.requestTokens = min(Double(requestPerMinute), bucket.requestTokens + add)
        }
        if let tokenPerMinute = policy.tokenBucketPerMinute {
            let add = elapsed * (Double(tokenPerMinute) / 60.0)
            bucket.tokenTokens = min(Double(tokenPerMinute), bucket.tokenTokens + add)
        }
    }

    private func effectiveInFlight() -> Int {
        inFlight + pendingResumes
    }

    private func effectiveModelCap(for modelID: UUID) -> Int? {
        if let override = policy.perModelCaps[modelID] {
            return override
        }
        return policy.maxConcurrentPerModel
    }

    private func effectiveCredentialCap(for credentialKey: String) -> Int? {
        if let override = policy.perCredentialCaps[credentialKey] {
            return override
        }
        return policy.maxConcurrentPerCredential
    }

    private func reservedTokenUnits(for reservation: ModelCallReservation) -> Int {
        max(1, reservation.estimatedTotalTokens ?? 1)
    }

    private func bucketScopeKey(for normalizedCredentialKey: String?) -> String {
        switch policy.bucketScope {
        case .global:
            return "__global__"
        case .perCredential:
            return normalizedCredentialKey ?? "__global__"
        }
    }

    private func normalizedCredentialKey(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func conversationFairnessKey(for conversationID: UUID?) -> String {
        conversationID?.uuidString ?? "__none__"
    }

    private func startRefillTickerIfNeeded() {
        guard (policy.requestBucketPerMinute != nil || policy.tokenBucketPerMinute != nil),
              hasQueuedWaiters,
              refillTickerTask == nil
        else {
            return
        }
        let intervalNs = UInt64(policy.bucketRefillGranularitySeconds * 1_000_000_000)
        refillTickerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                await self.onRefillTick()
            }
        }
    }

    private var hasQueuedWaiters: Bool {
        !foregroundWaiters.isEmpty || !backgroundWaiters.isEmpty
    }

    private func stopRefillTickerIfIdle() {
        guard !hasQueuedWaiters || (policy.requestBucketPerMinute == nil && policy.tokenBucketPerMinute == nil) else {
            return
        }
        refillTickerTask?.cancel()
        refillTickerTask = nil
    }

    private func onRefillTick() async {
        guard hasQueuedWaiters else {
            stopRefillTickerIfIdle()
            return
        }
        resumeWaitersIfPossible()
        await emitPoolHealth()
    }

    /// Pure selection helper: returns which queue to serve when a slot opens, or `nil` when both are empty.
    ///
    /// Foreground waiters win unless the head of the background queue has been waiting at least
    /// `starvationGrace` — at that point the background head is promoted so it cannot starve forever
    /// under sustained foreground load. Within a single priority class, FIFO is preserved by the caller
    /// (`Array.removeFirst()` on the chosen queue).
    static func selectNextWaiter(
        foregroundCount: Int,
        oldestBackgroundEnqueuedAt: Date?,
        now: Date,
        starvationGrace: TimeInterval
    ) -> WaiterChoice? {
        let backgroundWaiting: TimeInterval? = oldestBackgroundEnqueuedAt.map { now.timeIntervalSince($0) }
        let backgroundStarved = (backgroundWaiting ?? -1) >= starvationGrace
        if foregroundCount > 0, !(backgroundStarved && backgroundWaiting != nil) {
            return .foreground
        }
        if backgroundWaiting != nil { return .background }
        return foregroundCount > 0 ? .foreground : nil
    }
}
