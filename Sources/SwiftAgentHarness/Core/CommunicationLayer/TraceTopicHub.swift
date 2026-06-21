import Foundation
import Logging

/// Fan-out for `trace/{conversationId}` and `trace/server` topics.
public actor TraceTopicHub {
    public struct ConnectionToken: Hashable, Sendable {
        let uuid: UUID
        init() { self.uuid = UUID() }
    }

    private struct SubscriberEntry {
        var topics: Set<String> = []
        let sendWireLine: @Sendable (HarnessOutboundWireLine) async throws -> Void
    }

    private var inProcessSubscribers: [EmbeddedTopicSubscriberToken: EmbeddedTopicSubscriberEntry] = [:]
    private var seqByTopic: [String: Int] = [:]
    private var replayStore = TopicReplayStore()
    private var subscribers: [ConnectionToken: SubscriberEntry] = [:]
    private let logger: Logger?
    private let governance: PublishingGovernanceConfiguration
    private let replayCapacities: TopicReplayCapacityConfiguration

    public init(
        logger: Logger? = nil,
        governance: PublishingGovernanceConfiguration = .defaultStrict,
        replayCapacities: TopicReplayCapacityConfiguration = .default
    ) {
        self.logger = logger
        self.governance = governance
        self.replayCapacities = replayCapacities
    }

    public func registerConnection(sendWireLine: @escaping @Sendable (HarnessOutboundWireLine) async throws -> Void) -> ConnectionToken {
        let token = ConnectionToken()
        subscribers[token] = SubscriberEntry(sendWireLine: sendWireLine)
        return token
    }

    public func unregisterConnection(_ token: ConnectionToken) async {
        subscribers[token] = nil
    }

    public func subscribe(
        token: ConnectionToken,
        topic: String,
        since: Int?,
        snapshotProvider: @Sendable @escaping () async -> TraceTopicPayload
    ) async throws {
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = try await replayIfAvailable(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            try await sendLagging(token: token, topic: topic, seq: latestSeq)
        }

        let payload = await snapshotProvider()
        guard shouldPublish(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<TraceTopicPayload>(
                snapshot: topic,
                seq: seq,
                value: payload
            )
        )
    }

    public func subscribeInProcess(
        token: EmbeddedTopicSubscriberToken,
        topic: String,
        since: Int?,
        snapshotProvider: @Sendable @escaping () async -> TraceTopicPayload
    ) async {
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = await replayIfAvailableInProcess(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<TraceTopicPayload>(lagging: topic, seq: latestSeq, hint: "resync")
            await sendInProcess(token: token, envelope: envelope)
        }

        let payload = await snapshotProvider()
        guard shouldPublish(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<TraceTopicPayload>(
                snapshot: topic,
                seq: seq,
                value: payload
            )
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

    public func broadcastConversation(conversationID: UUID, payload: TraceTopicPayload) async {
        let topic = TraceTopicFormat.conversationTopic(conversationID: conversationID)
        guard shouldPublish(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<TraceTopicPayload>(event: topic, seq: seq, value: payload)
        await fanOut(topic: topic, envelope: envelope)
    }

    public func broadcastServer(payload: TraceTopicPayload) async {
        let topic = TraceTopicFormat.serverTopic
        guard shouldPublish(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<TraceTopicPayload>(event: topic, seq: seq, value: payload)
        await fanOut(topic: topic, envelope: envelope)
    }

    public func hasSubscribers(forTopic topic: String) -> Bool {
        subscribers.values.contains { $0.topics.contains(topic) }
            || inProcessSubscribers.values.contains { $0.topics.contains(topic) }
    }

    public func currentSeq(forTopic topic: String) -> Int {
        seqByTopic[topic] ?? 0
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
            guard let line = HarnessOutboundWireLine.makeValidatedReplay(json: json, hubLabel: "TraceTopicHub", logger: logger) else { continue }
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

    private func sendLagging(token: ConnectionToken, topic: String, seq: Int) async throws {
        let envelope = CommResourceTopicMessage<TraceTopicPayload>(lagging: topic, seq: seq, hint: "resync")
        try await send(token: token, envelope: envelope)
    }

    private func makeWireLine(_ envelope: CommResourceTopicMessage<TraceTopicPayload>) -> HarnessOutboundWireLine? {
        HarnessOutboundWireLine.makeOrLog(from: envelope, hubLabel: "TraceTopicHub", logger: logger)
    }

    private func send(
        token: ConnectionToken,
        envelope: CommResourceTopicMessage<TraceTopicPayload>
    ) async throws {
        guard let sub = subscribers[token] else { return }
        guard let line = makeWireLine(envelope) else { return }
        try await sub.sendWireLine(line)
    }

    private func sendLine(token: ConnectionToken, line: HarnessOutboundWireLine) async throws {
        guard let sub = subscribers[token] else { return }
        try await sub.sendWireLine(line)
    }

    private func sendInProcess(
        token: EmbeddedTopicSubscriberToken,
        envelope: CommResourceTopicMessage<TraceTopicPayload>
    ) async {
        guard let line = makeWireLine(envelope) else { return }
        await sendRawInProcess(token: token, json: line.json)
    }

    private func sendRawInProcess(token: EmbeddedTopicSubscriberToken, json: String) async {
        guard let sub = inProcessSubscribers[token] else { return }
        await sub.sendJSON(json)
    }

    private func fanOut(topic: String, envelope: CommResourceTopicMessage<TraceTopicPayload>) async {
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
                logger?.debug("TraceTopicHub: send failed, dropping subscriber: \(error)")
                subscribers[token] = nil
            }
        }

        let ipcSnapshot = inProcessSubscribers
        for (token, sub) in ipcSnapshot where sub.topics.contains(topic) {
            await sendRawInProcess(token: token, json: line.json)
        }
    }

    private func shouldPublish(payload: TraceTopicPayload, topic: String) -> Bool {
        let issues = PublishingContractValidator.validateTraceTopicPayload(payload)
        guard !issues.isEmpty else { return true }
        let detail = issues.joined(separator: "; ")
        if governance.diagnosticsEnabled || governance.rejectsInvalidPayloads {
            logger?.warning("TraceTopicHub publish contract validation failed [topic=\(topic), mode=\(governance.mode.rawValue)]: \(detail)")
        }
        return governance.rejectsInvalidPayloads == false
    }
}
