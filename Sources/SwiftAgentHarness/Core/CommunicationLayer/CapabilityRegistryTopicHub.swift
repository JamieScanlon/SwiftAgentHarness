import Foundation
import Logging

/// Fan-out for session capability registry topics (`tools/registry`, `skills/registry`, `sub-agents/registry`): per-topic seq, WebSocket subscribers keyed by connection token.
public actor CapabilityRegistryTopicHub {
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

    private var lastTools: ToolsRegistryPayload?
    private var lastSkills: SkillsRegistryPayload?
    private var lastSubAgents: SubAgentsRegistryPayload?

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

    public func subscribeToolsRegistry(
        token: ConnectionToken,
        since: Int?,
        snapshotProvider: @Sendable @escaping () async -> ToolsRegistryPayload
    ) async throws {
        let topic = ResourceTopicName.toolsRegistry
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = try await replayIfAvailable(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            try await sendLaggingTools(token: token, topic: topic, seq: latestSeq)
        }

        let payload = await snapshotProvider()
        guard shouldPublishTools(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        lastTools = payload
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<ToolsRegistryPayload>(
                snapshot: topic,
                seq: seq,
                value: payload,
                trustTag: .systemTrusted
            )
        )
    }

    public func subscribeToolsRegistryInProcess(
        token: EmbeddedTopicSubscriberToken,
        since: Int?,
        snapshotProvider: @Sendable @escaping () async -> ToolsRegistryPayload
    ) async {
        let topic = ResourceTopicName.toolsRegistry
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = await replayIfAvailableInProcess(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<ToolsRegistryPayload>(
                lagging: topic,
                seq: latestSeq,
                hint: "resync",
                trustTag: .systemTrusted
            )
            await sendInProcess(token: token, envelope: envelope)
        }

        let payload = await snapshotProvider()
        guard shouldPublishTools(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        lastTools = payload
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<ToolsRegistryPayload>(
                snapshot: topic,
                seq: seq,
                value: payload,
                trustTag: .systemTrusted
            )
        )
    }

    public func subscribeSkillsRegistry(
        token: ConnectionToken,
        since: Int?,
        snapshotProvider: @Sendable @escaping () async -> SkillsRegistryPayload
    ) async throws {
        let topic = ResourceTopicName.skillsRegistry
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = try await replayIfAvailable(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            try await sendLaggingSkills(token: token, topic: topic, seq: latestSeq)
        }

        let payload = await snapshotProvider()
        guard shouldPublishSkills(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        lastSkills = payload
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<SkillsRegistryPayload>(
                snapshot: topic,
                seq: seq,
                value: payload,
                trustTag: .systemTrusted
            )
        )
    }

    public func subscribeSkillsRegistryInProcess(
        token: EmbeddedTopicSubscriberToken,
        since: Int?,
        snapshotProvider: @Sendable @escaping () async -> SkillsRegistryPayload
    ) async {
        let topic = ResourceTopicName.skillsRegistry
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = await replayIfAvailableInProcess(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<SkillsRegistryPayload>(
                lagging: topic,
                seq: latestSeq,
                hint: "resync",
                trustTag: .systemTrusted
            )
            await sendInProcess(token: token, envelope: envelope)
        }

        let payload = await snapshotProvider()
        guard shouldPublishSkills(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        lastSkills = payload
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<SkillsRegistryPayload>(
                snapshot: topic,
                seq: seq,
                value: payload,
                trustTag: .systemTrusted
            )
        )
    }

    public func subscribeSubAgentsRegistry(
        token: ConnectionToken,
        since: Int?,
        snapshotProvider: @Sendable @escaping () async -> SubAgentsRegistryPayload
    ) async throws {
        let topic = ResourceTopicName.subAgentsRegistry
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = try await replayIfAvailable(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            try await sendLaggingSubAgents(token: token, topic: topic, seq: latestSeq)
        }

        let payload = await snapshotProvider()
        guard shouldPublishSubAgents(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        lastSubAgents = payload
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<SubAgentsRegistryPayload>(
                snapshot: topic,
                seq: seq,
                value: payload,
                trustTag: trustTag(for: payload)
            )
        )
    }

    public func subscribeSubAgentsRegistryInProcess(
        token: EmbeddedTopicSubscriberToken,
        since: Int?,
        snapshotProvider: @Sendable @escaping () async -> SubAgentsRegistryPayload
    ) async {
        let topic = ResourceTopicName.subAgentsRegistry
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestSeq = seqByTopic[topic] ?? 0
        let replayStatus = await replayIfAvailableInProcess(token: token, topic: topic, since: since, latestSeq: latestSeq)
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<SubAgentsRegistryPayload>(
                lagging: topic,
                seq: latestSeq,
                hint: "resync",
                trustTag: trustTag(for: lastSubAgents)
            )
            await sendInProcess(token: token, envelope: envelope)
        }

        let payload = await snapshotProvider()
        guard shouldPublishSubAgents(payload: payload, topic: topic) else { return }
        let seq = nextSeq(for: topic)
        lastSubAgents = payload
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<SubAgentsRegistryPayload>(
                snapshot: topic,
                seq: seq,
                value: payload,
                trustTag: trustTag(for: payload)
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

    public func broadcastToolsRegistry(_ payload: ToolsRegistryPayload) async {
        let topic = ResourceTopicName.toolsRegistry
        guard shouldPublishTools(payload: payload, topic: topic) else { return }
        lastTools = payload
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<ToolsRegistryPayload>(
            event: topic,
            seq: seq,
            value: payload,
            trustTag: .systemTrusted
        )
        await fanOut(topic: topic, envelope: envelope)
    }

    public func broadcastSkillsRegistry(_ payload: SkillsRegistryPayload) async {
        let topic = ResourceTopicName.skillsRegistry
        guard shouldPublishSkills(payload: payload, topic: topic) else { return }
        lastSkills = payload
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<SkillsRegistryPayload>(
            event: topic,
            seq: seq,
            value: payload,
            trustTag: .systemTrusted
        )
        await fanOut(topic: topic, envelope: envelope)
    }

    public func broadcastSubAgentsRegistry(_ payload: SubAgentsRegistryPayload) async {
        let topic = ResourceTopicName.subAgentsRegistry
        guard shouldPublishSubAgents(payload: payload, topic: topic) else { return }
        lastSubAgents = payload
        let seq = nextSeq(for: topic)
        let envelope = CommResourceTopicMessage<SubAgentsRegistryPayload>(
            event: topic,
            seq: seq,
            value: payload,
            trustTag: trustTag(for: payload)
        )
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
            guard let line = HarnessOutboundWireLine.makeValidatedReplay(json: json, hubLabel: "CapabilityRegistryTopicHub", logger: logger) else { continue }
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

    private func sendLaggingTools(token: ConnectionToken, topic: String, seq: Int) async throws {
        let envelope = CommResourceTopicMessage<ToolsRegistryPayload>(
            lagging: topic,
            seq: seq,
            hint: "resync",
            trustTag: .systemTrusted
        )
        try await send(token: token, envelope: envelope)
    }

    private func sendLaggingSkills(token: ConnectionToken, topic: String, seq: Int) async throws {
        let envelope = CommResourceTopicMessage<SkillsRegistryPayload>(
            lagging: topic,
            seq: seq,
            hint: "resync",
            trustTag: .systemTrusted
        )
        try await send(token: token, envelope: envelope)
    }

    private func sendLaggingSubAgents(token: ConnectionToken, topic: String, seq: Int) async throws {
        let envelope = CommResourceTopicMessage<SubAgentsRegistryPayload>(
            lagging: topic,
            seq: seq,
            hint: "resync",
            trustTag: trustTag(for: lastSubAgents)
        )
        try await send(token: token, envelope: envelope)
    }

    private func trustTag(for payload: SubAgentsRegistryPayload?) -> CommEnvelopeTrustTag {
        guard let payload else { return .unknownRestricted }
        let tags = payload.entries.map { entry in
            CommEnvelopeTrustTag.fromSubAgentTrustRaw(entry.defaultTrustLevel)
        }
        return CommEnvelopeTrustTag.mostRestrictive(tags, fallback: .unknownRestricted)
    }

    private func makeWireLine<Payload: Codable & Sendable>(_ envelope: CommResourceTopicMessage<Payload>) -> HarnessOutboundWireLine? {
        HarnessOutboundWireLine.makeOrLog(from: envelope, hubLabel: "CapabilityRegistryTopicHub", logger: logger)
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
                logger?.debug("CapabilityRegistryTopicHub: send failed, dropping subscriber: \(error)")
                subscribers[token] = nil
            }
        }

        let ipcSnapshot = inProcessSubscribers
        for (token, sub) in ipcSnapshot where sub.topics.contains(topic) {
            await sendRawInProcess(token: token, json: line.json)
        }
    }

    private func shouldPublishTools(payload: ToolsRegistryPayload, topic: String) -> Bool {
        shouldPublish(
            issues: PublishingContractValidator.validateToolsRegistryPayload(payload),
            topic: topic
        )
    }

    private func shouldPublishSkills(payload: SkillsRegistryPayload, topic: String) -> Bool {
        shouldPublish(
            issues: PublishingContractValidator.validateSkillsRegistryPayload(payload),
            topic: topic
        )
    }

    private func shouldPublishSubAgents(payload: SubAgentsRegistryPayload, topic: String) -> Bool {
        shouldPublish(
            issues: PublishingContractValidator.validateSubAgentsRegistryPayload(payload),
            topic: topic
        )
    }

    private func shouldPublish(issues: [String], topic: String) -> Bool {
        guard !issues.isEmpty else { return true }
        let detail = issues.joined(separator: "; ")
        if governance.diagnosticsEnabled || governance.rejectsInvalidPayloads {
            logger?.warning("CapabilityRegistryTopicHub publish contract validation failed [topic=\(topic), mode=\(governance.mode.rawValue)]: \(detail)")
        }
        return governance.rejectsInvalidPayloads == false
    }
}

