import Foundation

public struct PoolCommunicationAggregatesSnapshot: Sendable, Equatable {
    public var errorRate: Double?
    public var rollingLatencyMsP50: Double?
    public var rollingLatencyMsP95: Double?

    public init(
        errorRate: Double? = nil,
        rollingLatencyMsP50: Double? = nil,
        rollingLatencyMsP95: Double? = nil
    ) {
        self.errorRate = errorRate
        self.rollingLatencyMsP50 = rollingLatencyMsP50
        self.rollingLatencyMsP95 = rollingLatencyMsP95
    }
}

public struct ModelCommunicationAggregatesSnapshot: Sendable, Equatable {
    public var recentLatencyMsP50: Double?
    public var recentLatencyMsP95: Double?
    public var recentTokensPerSecond: Double?
    public var rateLimitWindow: ModelRateLimitWindow?

    public init(
        recentLatencyMsP50: Double? = nil,
        recentLatencyMsP95: Double? = nil,
        recentTokensPerSecond: Double? = nil,
        rateLimitWindow: ModelRateLimitWindow? = nil
    ) {
        self.recentLatencyMsP50 = recentLatencyMsP50
        self.recentLatencyMsP95 = recentLatencyMsP95
        self.recentTokensPerSecond = recentTokensPerSecond
        self.rateLimitWindow = rateLimitWindow
    }
}

public actor CommunicationAggregatesEngine {
    private let now: @Sendable () -> Date
    private let maxAttemptSamples: Int
    private let maxLatencySamples: Int
    private let rateLimitWindowSeconds: TimeInterval

    private struct AttemptOutcome: Sendable {
        let failed: Bool
    }

    private struct InFlightCallStart: Sendable {
        let modelID: UUID
        let startedAt: Date
    }

    private var callStarts: [UUID: InFlightCallStart] = [:]
    private var recentAttempts: [AttemptOutcome] = []
    private var poolLatencyMsSamples: [Double] = []
    private var modelLatencyMsSamples: [UUID: [Double]] = [:]
    private var modelTokensPerSecondSamples: [UUID: [Double]] = [:]
    private var modelRateLimitLastObservedAt: [UUID: Date] = [:]
    private var modelRateLimitRetryAfterSeconds: [UUID: Double] = [:]

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        maxAttemptSamples: Int = 256,
        maxLatencySamples: Int = 256,
        rateLimitWindowSeconds: TimeInterval = 60
    ) {
        self.now = now
        self.maxAttemptSamples = max(1, maxAttemptSamples)
        self.maxLatencySamples = max(1, maxLatencySamples)
        self.rateLimitWindowSeconds = max(1, rateLimitWindowSeconds)
    }

    public func recordAttempt(modelID: UUID, callID: UUID, startedAt: Date? = nil) {
        let start = startedAt ?? now()
        callStarts[callID] = InFlightCallStart(modelID: modelID, startedAt: start)
    }

    public func recordCompletion(
        modelID: UUID,
        callID: UUID,
        completionTokens: Int? = nil,
        completedAt: Date? = nil
    ) {
        let end = completedAt ?? now()
        recordAttemptOutcome(callID: callID, failed: false, completionTokens: completionTokens, completedAt: end)
    }

    public func recordFailure(modelID: UUID, callID: UUID, rateLimited: Bool = false, completedAt: Date? = nil) {
        let end = completedAt ?? now()
        if rateLimited {
            modelRateLimitLastObservedAt[modelID] = end
            modelRateLimitRetryAfterSeconds.removeValue(forKey: modelID)
        }
        recordAttemptOutcome(callID: callID, failed: true, completionTokens: nil, completedAt: end)
    }

    public func poolSnapshot() -> PoolCommunicationAggregatesSnapshot {
        let attempts = recentAttempts.count
        let failed = recentAttempts.reduce(0) { $0 + ($1.failed ? 1 : 0) }
        return PoolCommunicationAggregatesSnapshot(
            errorRate: attempts > 0 ? Double(failed) / Double(attempts) : nil,
            rollingLatencyMsP50: percentile(poolLatencyMsSamples, 0.5),
            rollingLatencyMsP95: percentile(poolLatencyMsSamples, 0.95)
        )
    }

    public func snapshot(for modelID: UUID) -> ModelCommunicationAggregatesSnapshot {
        let samples = modelLatencyMsSamples[modelID] ?? []
        let nowDate = now()
        let lastRateLimit = modelRateLimitLastObservedAt[modelID]
        let active: Bool
        if let lastRateLimit {
            active = nowDate.timeIntervalSince(lastRateLimit) <= rateLimitWindowSeconds
        } else {
            active = false
        }
        let rateLimitWindow = lastRateLimit.map { last in
            ModelRateLimitWindow(
                active: active,
                lastObservedAt: last,
                retryAfterSeconds: modelRateLimitRetryAfterSeconds[modelID]
            )
        }
        return ModelCommunicationAggregatesSnapshot(
            recentLatencyMsP50: percentile(samples, 0.5),
            recentLatencyMsP95: percentile(samples, 0.95),
            recentTokensPerSecond: percentile(modelTokensPerSecondSamples[modelID] ?? [], 0.5),
            rateLimitWindow: rateLimitWindow
        )
    }

    private func recordAttemptOutcome(callID: UUID, failed: Bool, completionTokens: Int?, completedAt: Date) {
        appendAttemptSample(AttemptOutcome(failed: failed))
        if let start = callStarts.removeValue(forKey: callID) {
            let elapsedMs = max(0, completedAt.timeIntervalSince(start.startedAt) * 1000.0)
            appendPoolLatencySample(elapsedMs)
            appendModelLatencySample(modelID: start.modelID, elapsedMs: elapsedMs)
            if let completionTokens, completionTokens > 0, elapsedMs > 0 {
                let tokensPerSecond = Double(completionTokens) / (elapsedMs / 1000.0)
                appendModelTokensPerSecondSample(modelID: start.modelID, tokensPerSecond: tokensPerSecond)
            }
        }
    }

    private func appendAttemptSample(_ sample: AttemptOutcome) {
        recentAttempts.append(sample)
        if recentAttempts.count > maxAttemptSamples {
            recentAttempts.removeFirst(recentAttempts.count - maxAttemptSamples)
        }
    }

    private func appendPoolLatencySample(_ sample: Double) {
        poolLatencyMsSamples.append(sample)
        if poolLatencyMsSamples.count > maxLatencySamples {
            poolLatencyMsSamples.removeFirst(poolLatencyMsSamples.count - maxLatencySamples)
        }
    }

    private func appendModelLatencySample(modelID: UUID, elapsedMs: Double) {
        var samples = modelLatencyMsSamples[modelID] ?? []
        samples.append(elapsedMs)
        if samples.count > maxLatencySamples {
            samples.removeFirst(samples.count - maxLatencySamples)
        }
        modelLatencyMsSamples[modelID] = samples
    }

    private func appendModelTokensPerSecondSample(modelID: UUID, tokensPerSecond: Double) {
        var samples = modelTokensPerSecondSamples[modelID] ?? []
        samples.append(tokensPerSecond)
        if samples.count > maxLatencySamples {
            samples.removeFirst(samples.count - maxLatencySamples)
        }
        modelTokensPerSecondSamples[modelID] = samples
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(1.0, max(0.0, p))
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }
}

