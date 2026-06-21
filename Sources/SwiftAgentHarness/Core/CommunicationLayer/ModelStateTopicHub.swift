import Foundation
import Logging
import Vapor

/// Fan-out for resource topics (`model/{id}/state`, `pool/health`, `models/registry`): per-topic seq, subscribers keyed by connection token.
public actor ModelStateTopicHub {
    public struct ConnectionToken: Hashable, Sendable {
        let uuid: UUID
        init() { self.uuid = UUID() }
    }

    private struct ModelTopicSubscriberEntry {
        var topics: Set<String> = []
        let sendWireLine: @Sendable (HarnessOutboundWireLine) async throws -> Void
    }

    private var seqByTopic: [String: Int] = [:]
    private var replayStore = TopicReplayStore()
    private var subscribers: [ConnectionToken: ModelTopicSubscriberEntry] = [:]
    private let logger: Logger?
    private let replayCapacities: TopicReplayCapacityConfiguration

    /// In-process subscribers use the same topic contract as WebSocket subscribers.
    private var inProcessSubscribers: [EmbeddedTopicSubscriberToken: EmbeddedTopicSubscriberEntry] = [:]

    /// Latest pool health (for new subscribers and snapshots).
    private var lastPoolHealth: PoolHealthPayload
    /// Latest registry snapshot; nil until first publish from ``ModelManager``.
    private var lastRegistry: ModelsRegistryPayload?
    /// Latest `model/{id}/calls` snapshot by model.
    private var lastCallsByModelID: [UUID: ModelCallsPayload] = [:]

    public init(
        logger: Logger? = nil,
        defaultMaxConcurrentForHealth: Int = 8,
        replayCapacities: TopicReplayCapacityConfiguration = .default
    ) {
        self.logger = logger
        self.replayCapacities = replayCapacities
        self.lastPoolHealth = PoolHealthPayload(
            queueDepth: 0,
            inFlight: 0,
            maxConcurrent: max(1, defaultMaxConcurrentForHealth)
        )
    }

    /// Register a WebSocket subscriber; returns a token used for unsubscribe-on-close.
    public func registerConnection(sendWireLine: @escaping @Sendable (HarnessOutboundWireLine) async throws -> Void) -> ConnectionToken {
        let token = ConnectionToken()
        subscribers[token] = ModelTopicSubscriberEntry(sendWireLine: sendWireLine)
        return token
    }

    public func unregisterConnection(_ token: ConnectionToken) async {
        subscribers[token] = nil
    }

    /// Subscribe to `model/{uuid}/state`. Replays buffered event range when `since` is in-window; otherwise sends lagging + snapshot.
    public func subscribe(
        token: ConnectionToken,
        modelID: UUID,
        since: Int?,
        snapshotProvider: @Sendable @escaping (UUID) async -> ModelStatePayload
    ) async throws {
        let topic = ModelStateTopicFormat.topic(modelID: modelID)
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = try await replayIfAvailable(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            try await sendLaggingModelState(token: token, topic: topic, seq: latestSeq)
        }

        let seq = nextSeq(for: topic)
        let payload = await snapshotProvider(modelID)
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<ModelStatePayload>(snapshot: topic, seq: seq, value: payload)
        )
    }

    /// Subscribe to `model/{uuid}/calls`. Replays buffered event range when `since` is in-window; otherwise sends lagging + snapshot.
    public func subscribeModelCalls(
        token: ConnectionToken,
        modelID: UUID,
        since: Int?,
        snapshotProvider: @Sendable @escaping (UUID) async -> ModelCallsPayload
    ) async throws {
        let topic = ModelCallsTopicFormat.topic(modelID: modelID)
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = try await replayIfAvailable(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<ModelCallsPayload>(lagging: topic, seq: latestSeq, hint: "resync")
            try await send(token: token, envelope: envelope)
        }

        let seq = nextSeq(for: topic)
        let payload = await snapshotProvider(modelID)
        lastCallsByModelID[modelID] = payload
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<ModelCallsPayload>(snapshot: topic, seq: seq, value: payload)
        )
    }

    /// In-process subscribe to `model/{uuid}/state`. Mirrors WebSocket reconcile-and-watch behavior.
    public func subscribeInProcess(
        token: EmbeddedTopicSubscriberToken,
        modelID: UUID,
        since: Int?,
        snapshotProvider: @Sendable @escaping (UUID) async -> ModelStatePayload
    ) async {
        let topic = ModelStateTopicFormat.topic(modelID: modelID)
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = await replayIfAvailableInProcess(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<ModelStatePayload>(lagging: topic, seq: latestSeq, hint: "resync")
            await sendInProcess(token: token, envelope: envelope)
        }

        let seq = nextSeq(for: topic)
        let payload = await snapshotProvider(modelID)
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<ModelStatePayload>(snapshot: topic, seq: seq, value: payload)
        )
    }

    public func subscribeModelCallsInProcess(
        token: EmbeddedTopicSubscriberToken,
        modelID: UUID,
        since: Int?,
        snapshotProvider: @Sendable @escaping (UUID) async -> ModelCallsPayload
    ) async {
        let topic = ModelCallsTopicFormat.topic(modelID: modelID)
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = await replayIfAvailableInProcess(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<ModelCallsPayload>(lagging: topic, seq: latestSeq, hint: "resync")
            await sendInProcess(token: token, envelope: envelope)
        }

        let seq = nextSeq(for: topic)
        let payload = await snapshotProvider(modelID)
        lastCallsByModelID[modelID] = payload
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<ModelCallsPayload>(snapshot: topic, seq: seq, value: payload)
        )
    }

    /// Subscribe to `pool/health`.
    public func subscribePoolHealth(token: ConnectionToken, since: Int?) async throws {
        let topic = ResourceTopicName.poolHealth
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = try await replayIfAvailable(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            try await sendLaggingPoolHealth(token: token, topic: topic, seq: latestSeq)
        }

        let seq = nextSeq(for: topic)
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<PoolHealthPayload>(snapshot: topic, seq: seq, value: lastPoolHealth)
        )
    }

    public func subscribePoolHealthInProcess(token: EmbeddedTopicSubscriberToken, since: Int?) async {
        let topic = ResourceTopicName.poolHealth
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = await replayIfAvailableInProcess(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<PoolHealthPayload>(lagging: topic, seq: latestSeq, hint: "resync")
            await sendInProcess(token: token, envelope: envelope)
        }

        let seq = nextSeq(for: topic)
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<PoolHealthPayload>(snapshot: topic, seq: seq, value: lastPoolHealth)
        )
    }

    /// Subscribe to `models/registry`.
    public func subscribeModelsRegistry(token: ConnectionToken, since: Int?) async throws {
        let topic = ResourceTopicName.modelsRegistry
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = try await replayIfAvailable(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            try await sendLaggingRegistry(token: token, topic: topic, seq: latestSeq)
        }

        let seq = nextSeq(for: topic)
        let snapshot = lastRegistry ?? ModelsRegistryPayload(models: [])
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<ModelsRegistryPayload>(snapshot: topic, seq: seq, value: snapshot)
        )
    }

    public func subscribeModelsRegistryInProcess(token: EmbeddedTopicSubscriberToken, since: Int?) async {
        let topic = ResourceTopicName.modelsRegistry
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = await replayIfAvailableInProcess(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<ModelsRegistryPayload>(lagging: topic, seq: latestSeq, hint: "resync")
            await sendInProcess(token: token, envelope: envelope)
        }

        let seq = nextSeq(for: topic)
        let snapshot = lastRegistry ?? ModelsRegistryPayload(models: [])
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<ModelsRegistryPayload>(snapshot: topic, seq: seq, value: snapshot)
        )
    }

    public func unsubscribe(token: ConnectionToken, topic: String) {
        guard var sub = subscribers[token] else { return }
        sub.topics.remove(topic)
        subscribers[token] = sub
    }

    public func unsubscribeInProcess(token: EmbeddedTopicSubscriberToken, topic: String) {
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.remove(topic)
        inProcessSubscribers[token] = sub
    }

    /// Register an in-process subscriber. Topic-scoped delivery starts after explicit subscribe calls.
    public func registerInProcessSubscriber(
        _ handler: @escaping @Sendable (String) async -> Void
    ) -> EmbeddedTopicSubscriberToken {
        let token = EmbeddedTopicSubscriberToken()
        inProcessSubscribers[token] = EmbeddedTopicSubscriberEntry(sendJSON: handler)
        return token
    }

    public func unregisterInProcessSubscriber(_ token: EmbeddedTopicSubscriberToken) {
        inProcessSubscribers[token] = nil
    }

    /// Broadcast a state change originating from ``ModelInvocationCoordinator``.
    public func broadcast(modelID: UUID, payload: ModelStatePayload) async {
        let topic = ModelStateTopicFormat.topic(modelID: modelID)
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<ModelStatePayload>(event: topic, seq: seq, value: payload)
        await fanOut(topic: topic, envelope: envelope)
    }

    /// Broadcast a call-ledger update originating from ``ModelInvocationCoordinator``.
    public func broadcastModelCalls(modelID: UUID, payload: ModelCallsPayload) async {
        lastCallsByModelID[modelID] = payload
        let topic = ModelCallsTopicFormat.topic(modelID: modelID)
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<ModelCallsPayload>(event: topic, seq: seq, value: payload)
        await fanOut(topic: topic, envelope: envelope)
    }

    /// Broadcast scheduler / pool aggregate health.
    public func broadcastPoolHealth(_ payload: PoolHealthPayload) async {
        lastPoolHealth = payload
        let topic = ResourceTopicName.poolHealth
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<PoolHealthPayload>(event: topic, seq: seq, value: payload)
        await fanOut(topic: topic, envelope: envelope)
    }

    /// Broadcast full models registry snapshot; sends an `event` envelope and
    /// updates the cached snapshot served on subscribe.
    public func broadcastModelsRegistry(_ payload: ModelsRegistryPayload) async {
        lastRegistry = payload
        let topic = ResourceTopicName.modelsRegistry
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<ModelsRegistryPayload>(event: topic, seq: seq, value: payload)
        await fanOut(topic: topic, envelope: envelope)
    }

    /// Updates the cached `models/registry` snapshot served to new subscribers. Does **not**
    /// fan out an event — the producer is expected to follow up with ``broadcastModelsRegistryEvent(_:)``
    /// when a granular delta is available.
    public func cacheRegistrySnapshot(_ payload: ModelsRegistryPayload) async {
        lastRegistry = payload
    }

    /// Fans out a granular `models/registry` event with per-model deltas. Sequence numbers share
    /// the topic counter with snapshots, so subscribers can detect lag the same way for both kinds.
    public func broadcastModelsRegistryEvent(_ payload: ModelsRegistryEventPayload) async {
        let topic = ResourceTopicName.modelsRegistry
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<ModelsRegistryEventPayload>(event: topic, seq: seq, value: payload)
        await fanOut(topic: topic, envelope: envelope)
    }

    public func currentSeq(forModelID modelID: UUID) -> Int {
        let topic = ModelStateTopicFormat.topic(modelID: modelID)
        return seqByTopic[topic] ?? 0
    }

    private func nextSeq(for topic: String) -> Int {
        let next = (seqByTopic[topic] ?? 0) + 1
        seqByTopic[topic] = next
        return next
    }

    private enum ReplayStatus {
        case notRequested
        case replayed
        case laggingRequired
    }

    private func replayIfAvailable(
        token: ConnectionToken,
        topic: String,
        since: Int?,
        latestSeq: Int
    ) async throws -> ReplayStatus {
        guard let since else { return .notRequested }
        if latestSeq == 0 {
            // No buffered server history yet; `since > 0` implies the client's cursor cannot be replayed.
            return since > 0 ? .laggingRequired : .notRequested
        }
        if since == latestSeq {
            return .notRequested
        }
        guard since < latestSeq else {
            return .laggingRequired
        }
        guard let replay = replayStore.replayRange(topic: topic, fromExclusive: since, toInclusive: latestSeq) else {
            return .laggingRequired
        }
        for json in replay {
            guard let line = HarnessOutboundWireLine.makeValidatedReplay(json: json, hubLabel: "ModelStateTopicHub", logger: logger) else { continue }
            try await sendLine(token: token, line: line)
        }
        return .replayed
    }

    private func replayIfAvailableInProcess(
        token: EmbeddedTopicSubscriberToken,
        topic: String,
        since: Int?,
        latestSeq: Int
    ) async -> ReplayStatus {
        guard let since else { return .notRequested }
        if latestSeq == 0 {
            return since > 0 ? .laggingRequired : .notRequested
        }
        if since == latestSeq {
            return .notRequested
        }
        guard since < latestSeq else {
            return .laggingRequired
        }
        guard let replay = replayStore.replayRange(topic: topic, fromExclusive: since, toInclusive: latestSeq) else {
            return .laggingRequired
        }
        for json in replay {
            await sendRawInProcess(token: token, json: json)
        }
        return .replayed
    }

    private func sendLaggingModelState(token: ConnectionToken, topic: String, seq: Int) async throws {
        let envelope = CommResourceTopicMessage<ModelStatePayload>(lagging: topic, seq: seq, hint: "resync")
        try await send(token: token, envelope: envelope)
    }

    private func sendLaggingPoolHealth(token: ConnectionToken, topic: String, seq: Int) async throws {
        let envelope = CommResourceTopicMessage<PoolHealthPayload>(lagging: topic, seq: seq, hint: "resync")
        try await send(token: token, envelope: envelope)
    }

    private func sendLaggingRegistry(token: ConnectionToken, topic: String, seq: Int) async throws {
        let envelope = CommResourceTopicMessage<ModelsRegistryPayload>(lagging: topic, seq: seq, hint: "resync")
        try await send(token: token, envelope: envelope)
    }

    private func makeWireLine<Payload: Codable & Sendable>(_ envelope: CommResourceTopicMessage<Payload>) -> HarnessOutboundWireLine? {
        HarnessOutboundWireLine.makeOrLog(from: envelope, hubLabel: "ModelStateTopicHub", logger: logger)
    }

    private func send<Payload: Codable & Sendable>(
        token: ConnectionToken,
        envelope: CommResourceTopicMessage<Payload>
    ) async throws {
        guard let sub = subscribers[token] else { return }
        guard let line = makeWireLine(envelope) else { return }
        try await sub.sendWireLine(line)
    }

    private func sendLine(token: ConnectionToken, line: HarnessOutboundWireLine) async throws {
        guard let sub = subscribers[token] else { return }
        try await sub.sendWireLine(line)
    }

    private func sendInProcess<Payload: Codable & Sendable>(
        token: EmbeddedTopicSubscriberToken,
        envelope: CommResourceTopicMessage<Payload>
    ) async {
        guard let line = makeWireLine(envelope) else { return }
        await sendRawInProcess(token: token, json: line.json)
    }

    private func sendRawInProcess(token: EmbeddedTopicSubscriberToken, json: String) async {
        guard let sub = inProcessSubscribers[token] else { return }
        await sub.sendJSON(json)
    }

    private func fanOut<Payload: Codable & Sendable>(
        topic: String,
        envelope: CommResourceTopicMessage<Payload>
    ) async {
        guard let line = makeWireLine(envelope) else { return }
        if envelope.kind == .event, let seq = envelope.seq {
            replayStore.append(
                topic: topic,
                seq: seq,
                json: line.json,
                capacity: replayCapacities.capacity(for: topic)
            )
        }

        let wsSnapshot = subscribers
        for (token, sub) in wsSnapshot where sub.topics.contains(topic) {
            do {
                try await sendLine(token: token, line: line)
            } catch {
                logger?.debug("ModelStateTopicHub: send failed, dropping subscriber: \(error)")
                subscribers[token] = nil
            }
        }

        let ipcSnapshot = inProcessSubscribers
        for (token, sub) in ipcSnapshot where sub.topics.contains(topic) {
            await sendRawInProcess(token: token, json: line.json)
        }
    }
}

extension ModelStateTopicHub: ModelPoolResourceTopicPublishing {}
