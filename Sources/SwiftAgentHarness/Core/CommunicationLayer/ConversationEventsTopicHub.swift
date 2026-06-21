import Foundation
import Logging

/// Fan-out for ``ConversationTopicFormat`` topics. Every outbound envelope now carries top-level `seq`.
/// Persisted replay cursors continue to use `messageSeq` / `checkpointSeq` aligned with transcript sequence.
public actor ConversationEventsTopicHub {
    public struct ConnectionToken: Hashable, Sendable {
        let uuid: UUID
        init() { self.uuid = UUID() }
    }

    private struct SubscriberEntry {
        var topics: Set<String> = []
        let sendWireLine: @Sendable (HarnessOutboundWireLine) async throws -> Void
    }

    private var subscribers: [ConnectionToken: SubscriberEntry] = [:]
    private var inProcessSubscribers: [EmbeddedTopicSubscriberToken: EmbeddedTopicSubscriberEntry] = [:]
    /// Last envelope-level wire sequence observed per topic.
    private var lastWireSeqByTopic: [String: Int] = [:]
    /// Last persisted transcript sequence observed per topic.
    private var lastPersistedSeqByTopic: [String: Int] = [:]
    private var lastPersistedMessageSeqByTopic: [String: Int] = [:]
    private var lastPersistedCheckpointSeqByTopic: [String: Int] = [:]
    /// Transient ordinal per `(conversationUUID):(runUUID)` key.
    private var transientOrdinalByRunKey: [String: Int] = [:]
    private let logger: Logger?
    private let governance: PublishingGovernanceConfiguration
    private let resumeTokenHMACSecret: String?

    public init(
        logger: Logger? = nil,
        governance: PublishingGovernanceConfiguration = .defaultStrict,
        replayCapacities: TopicReplayCapacityConfiguration = .default,
        resumeTokenHMACSecret: String? = nil
    ) {
        self.logger = logger
        self.governance = governance
        self.resumeTokenHMACSecret = {
            guard let raw = resumeTokenHMACSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }()
        _ = replayCapacities // retained for future ring / capacity tuning; store replay is authoritative (P2)
    }

    public func registerConnection(sendWireLine: @escaping @Sendable (HarnessOutboundWireLine) async throws -> Void) -> ConnectionToken {
        let token = ConnectionToken()
        subscribers[token] = SubscriberEntry(sendWireLine: sendWireLine)
        return token
    }

    public func unregisterConnection(_ token: ConnectionToken) async {
        subscribers[token] = nil
    }

    /// Subscribe to `conversation/{uuid}/events`. Snapshot is UTF-8 JSON array text.
    public func subscribe(
        token: ConnectionToken,
        conversationID: UUID,
        since: Int?,
        transcriptReplay: ConversationTranscriptSubscribeReplay,
        snapshotMessagesJSONUTF8: @Sendable @escaping (UUID) async -> String,
        snapshotTranscriptSequence: Int?
    ) async throws {
        try await subscribe(
            token: token,
            conversationID: conversationID,
            replay: .totalOrderSince(since),
            transcriptReplay: transcriptReplay,
            snapshotMessagesJSONUTF8: snapshotMessagesJSONUTF8,
            snapshotTranscriptSequence: snapshotTranscriptSequence
        )
    }

    public func subscribe(
        token: ConnectionToken,
        conversationID: UUID,
        replay: ConversationEventsReplayRequest,
        transcriptReplay: ConversationTranscriptSubscribeReplay,
        snapshotMessagesJSONUTF8: @Sendable @escaping (UUID) async -> String,
        snapshotTranscriptSequence: Int?
    ) async throws {
        let topic = ConversationTopicFormat.topic(conversationID: conversationID)
        guard var sub = subscribers[token] else { return }
        sub.topics.insert(topic)
        subscribers[token] = sub

        let latestTotal = transcriptReplay.latestTotal
        let latestMessage = transcriptReplay.latestMessage
        let latestCheckpoint = transcriptReplay.latestCheckpoint

        let replayStatus = try await replayPersistedForSubscribe(
            token: token,
            topic: topic,
            replay: replay,
            transcriptReplay: transcriptReplay,
            latestTotal: latestTotal,
            latestMessage: latestMessage,
            latestCheckpoint: latestCheckpoint
        )
        let latestWire = lastWireSeqByTopic[topic] ?? 0
        let resumeToken = mintResumeToken(
            conversationID: conversationID,
            latestMessage: latestMessage,
            latestCheckpoint: latestCheckpoint,
            latestTotal: latestTotal
        )
        if replayStatus == .laggingRequired {
            try await sendLagging(token: token, topic: topic, seq: max(max(latestTotal, 0), latestWire), resumeToken: resumeToken)
        }

        let json = await snapshotMessagesJSONUTF8(conversationID)
        let payload = ConversationTopicEventPayload.messagesRefreshJSONUTF8(json)
        guard shouldPublish(payload: payload, topic: topic) else { return }
        let snapSeq = max(snapshotTranscriptSequence ?? latestTotal, latestWire)
        try await send(
            token: token,
            envelope: CommResourceTopicMessage<ConversationTopicEventPayload>(
                snapshot: topic,
                seq: snapSeq,
                value: payload,
                resumeToken: resumeToken,
                trustTag: trustTag(for: payload)
            )
        )
    }

    public func unsubscribe(token: ConnectionToken, topic: String) {
        guard var sub = subscribers[token] else { return }
        sub.topics.remove(topic)
        subscribers[token] = sub
    }

    public func subscribeInProcess(
        token: EmbeddedTopicSubscriberToken,
        conversationID: UUID,
        since: Int?,
        transcriptReplay: ConversationTranscriptSubscribeReplay,
        snapshotMessagesJSONUTF8: @Sendable @escaping (UUID) async -> String,
        snapshotTranscriptSequence: Int?
    ) async {
        await subscribeInProcess(
            token: token,
            conversationID: conversationID,
            replay: .totalOrderSince(since),
            transcriptReplay: transcriptReplay,
            snapshotMessagesJSONUTF8: snapshotMessagesJSONUTF8,
            snapshotTranscriptSequence: snapshotTranscriptSequence
        )
    }

    public func subscribeInProcess(
        token: EmbeddedTopicSubscriberToken,
        conversationID: UUID,
        replay: ConversationEventsReplayRequest,
        transcriptReplay: ConversationTranscriptSubscribeReplay,
        snapshotMessagesJSONUTF8: @Sendable @escaping (UUID) async -> String,
        snapshotTranscriptSequence: Int?
    ) async {
        let topic = ConversationTopicFormat.topic(conversationID: conversationID)
        guard var sub = inProcessSubscribers[token] else { return }
        sub.topics.insert(topic)
        inProcessSubscribers[token] = sub

        let latestTotal = transcriptReplay.latestTotal
        let latestMessage = transcriptReplay.latestMessage
        let latestCheckpoint = transcriptReplay.latestCheckpoint

        let replayStatus = await replayPersistedForSubscribeInProcess(
            token: token,
            topic: topic,
            replay: replay,
            transcriptReplay: transcriptReplay,
            latestTotal: latestTotal,
            latestMessage: latestMessage,
            latestCheckpoint: latestCheckpoint
        )
        let latestWire = lastWireSeqByTopic[topic] ?? 0
        let resumeToken = mintResumeToken(
            conversationID: conversationID,
            latestMessage: latestMessage,
            latestCheckpoint: latestCheckpoint,
            latestTotal: latestTotal
        )
        if replayStatus == .laggingRequired {
            let envelope = CommResourceTopicMessage<ConversationTopicEventPayload>(
                lagging: topic,
                seq: max(max(latestTotal, 0), latestWire),
                hint: "resync",
                resumeToken: resumeToken,
                trustTag: .unknownRestricted
            )
            await sendInProcess(token: token, envelope: envelope)
        }

        let json = await snapshotMessagesJSONUTF8(conversationID)
        let payload = ConversationTopicEventPayload.messagesRefreshJSONUTF8(json)
        guard shouldPublish(payload: payload, topic: topic) else { return }
        let snapSeq = max(snapshotTranscriptSequence ?? latestTotal, latestWire)
        await sendInProcess(
            token: token,
            envelope: CommResourceTopicMessage<ConversationTopicEventPayload>(
                snapshot: topic,
                seq: snapSeq,
                value: payload,
                resumeToken: resumeToken,
                trustTag: trustTag(for: payload)
            )
        )
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

    /// Persisted transcript event: wire `seq`, `messageSeq`, `checkpointSeq` match ``transcriptSequence``.
    public func broadcastPersisted(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        transcriptSequence: Int
    ) async {
        let topic = ConversationTopicFormat.topic(conversationID: conversationID)
        guard shouldPublish(payload: payload, topic: topic) else { return }
        let stream = ConversationEventsReplayClassifier.stream(for: payload)
        let msgSeq: Int?
        let chkSeq: Int?
        switch stream {
        case .persistedMessage:
            msgSeq = transcriptSequence
            chkSeq = nil
        case .persistedCheckpoint:
            msgSeq = nil
            chkSeq = transcriptSequence
        case .transient:
            return await broadcastTransient(
                conversationID: conversationID,
                payload: payload,
                runID: UUID(),
                modelCallId: nil
            )
        }
        let wireSeq = max(nextWireSeq(for: topic), transcriptSequence)
        let envelope = CommResourceTopicMessage<ConversationTopicEventPayload>(
            event: topic,
            seq: wireSeq,
            value: payload,
            messageSeq: msgSeq,
            checkpointSeq: chkSeq,
            trustTag: trustTag(for: payload)
        )
        lastWireSeqByTopic[topic] = max(lastWireSeqByTopic[topic] ?? 0, wireSeq)
        lastPersistedSeqByTopic[topic] = max(lastPersistedSeqByTopic[topic] ?? 0, transcriptSequence)
        if let m = msgSeq {
            lastPersistedMessageSeqByTopic[topic] = max(lastPersistedMessageSeqByTopic[topic] ?? 0, m)
        }
        if let c = chkSeq {
            lastPersistedCheckpointSeqByTopic[topic] = max(lastPersistedCheckpointSeqByTopic[topic] ?? 0, c)
        }
        await fanOut(topic: topic, envelope: envelope)
    }

    /// Transient conversation events (streaming deltas, runtime/model lifecycle, etc.).
    public func broadcastTransient(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        runID: UUID,
        modelCallId: UUID? = nil
    ) async {
        let topic = ConversationTopicFormat.topic(conversationID: conversationID)
        guard shouldPublish(payload: payload, topic: topic) else { return }
        let stream = ConversationEventsReplayClassifier.stream(for: payload)
        guard stream == .transient else { return }
        let key = transientRunKey(conversationID: conversationID, runID: runID)
        let nextOrdinal = (transientOrdinalByRunKey[key] ?? 0) + 1
        transientOrdinalByRunKey[key] = nextOrdinal
        let inboundBytes = payload.jsonUTF8?.utf8.count ?? 0
        logger?.debug(
            "ConversationEventsTopicHub broadcastTransient queued conversationID=\(conversationID.uuidString) semanticKind=\(payload.semanticKind.rawValue) runID=\(runID.uuidString) turnOrdinal=\(nextOrdinal) payloadBytes=\(inboundBytes)"
        )
        if payload.semanticKind == .runtimeLifecycle,
           let json = payload.jsonUTF8, json.contains("tool.approval") {
            let socketSubs = subscribers.values.filter { $0.topics.contains(topic) }.count
            let ipcSubs = inProcessSubscribers.values.filter { $0.topics.contains(topic) }.count
            logger?.debug(
                "[approval-trace] hub broadcastTransient runtimeLifecycle conversationID=\(conversationID.uuidString) socketSubscribers=\(socketSubs) ipcSubscribers=\(ipcSubs) payloadBytes=\(inboundBytes)"
            )
        }

        var valuePayload = payload
        if payload.semanticKind == .contentDelta, let json = payload.jsonUTF8, let data = json.data(using: .utf8),
           var wire = try? JSONDecoder().decode(ModelContentDeltaWire.self, from: data) {
            wire.runId = wire.runId ?? runID
            wire.callId = wire.callId ?? modelCallId
            if let encData = try? JSONEncoder().encode(wire), let s = String(data: encData, encoding: .utf8) {
                valuePayload = ConversationTopicEventPayload.contentDeltaJSONUTF8(s)
            }
        }

        let wireSeq = nextWireSeq(for: topic)
        let envelope = CommResourceTopicMessage<ConversationTopicEventPayload>(
            transientEvent: topic,
            seq: wireSeq,
            value: valuePayload,
            runId: runID,
            turnOrdinal: nextOrdinal,
            trustTag: trustTag(for: valuePayload)
        )
        lastWireSeqByTopic[topic] = max(lastWireSeqByTopic[topic] ?? 0, wireSeq)
        let outboundBytes = valuePayload.jsonUTF8?.utf8.count ?? 0
        logger?.debug(
            "ConversationEventsTopicHub broadcastTransient envelope conversationID=\(conversationID.uuidString) topic=\(topic) semanticKind=\(valuePayload.semanticKind.rawValue) seq=\(wireSeq) runID=\(runID.uuidString) turnOrdinal=\(nextOrdinal) payloadBytes=\(outboundBytes)"
        )
        await fanOut(topic: topic, envelope: envelope)
    }

    /// Compatibility broadcast entrypoint: routes to persisted vs transient using classifier.
    public func broadcast(conversationID: UUID, payload: ConversationTopicEventPayload) async {
        switch ConversationEventsReplayClassifier.stream(for: payload) {
        case .transient:
            await broadcastTransient(conversationID: conversationID, payload: payload, runID: UUID(), modelCallId: nil)
        case .persistedMessage, .persistedCheckpoint:
            let topic = ConversationTopicFormat.topic(conversationID: conversationID)
            let next = (lastPersistedSeqByTopic[topic] ?? 0) + 1
            await broadcastPersisted(conversationID: conversationID, payload: payload, transcriptSequence: next)
        }
    }

    public func currentSeq(forConversationID id: UUID) -> Int {
        let topic = ConversationTopicFormat.topic(conversationID: id)
        return lastWireSeqByTopic[topic] ?? 0
    }

    public func currentMessageSeq(forConversationID id: UUID) -> Int {
        let topic = ConversationTopicFormat.topic(conversationID: id)
        return lastPersistedMessageSeqByTopic[topic] ?? 0
    }

    public func currentCheckpointSeq(forConversationID id: UUID) -> Int {
        let topic = ConversationTopicFormat.topic(conversationID: id)
        return lastPersistedCheckpointSeqByTopic[topic] ?? 0
    }

    /// Skip dual-write when no subscriber has this conversation topic.
    public func hasSubscribers(forConversationID id: UUID) -> Bool {
        let topic = ConversationTopicFormat.topic(conversationID: id)
        return subscribers.values.contains { $0.topics.contains(topic) }
            || inProcessSubscribers.values.contains { $0.topics.contains(topic) }
    }

    private func transientRunKey(conversationID: UUID, runID: UUID) -> String {
        "\(conversationID.uuidString.lowercased()):\(runID.uuidString.lowercased())"
    }

    private func nextWireSeq(for topic: String) -> Int {
        let next = (lastWireSeqByTopic[topic] ?? 0) + 1
        lastWireSeqByTopic[topic] = next
        return next
    }

    private enum ReplayStatus {
        case notRequested
        case replayed
        case laggingRequired
    }

    private func replayPersistedForSubscribe(
        token: ConnectionToken,
        topic: String,
        replay: ConversationEventsReplayRequest,
        transcriptReplay: ConversationTranscriptSubscribeReplay,
        latestTotal: Int,
        latestMessage: Int,
        latestCheckpoint: Int
    ) async throws -> ReplayStatus {
        if transcriptReplay.forceLagging {
            return .laggingRequired
        }
        switch replay {
        case .totalOrderSince(let since):
            // Single-cursor `since` remains transcript-head based. If callers pass a higher envelope seq
            // (for example after transient traffic), do not force lagging; just skip persisted replay.
            if let since, since > latestTotal { return .notRequested }
        case .dual(let sinceM, let sinceC):
            if let sm = sinceM, sm > latestMessage { return .laggingRequired }
            if let sc = sinceC, sc > latestCheckpoint { return .laggingRequired }
        }

        let lines = transcriptReplay.persistedReplayLines
        for json in lines {
            guard let line = HarnessOutboundWireLine.makeValidatedReplay(json: json, hubLabel: "ConversationEventsTopicHub", logger: logger) else { continue }
            noteWireSeq(from: line, topic: topic)
            try await sendLine(token: token, line: line)
        }
        return lines.isEmpty ? .notRequested : .replayed
    }

    private func replayPersistedForSubscribeInProcess(
        token: EmbeddedTopicSubscriberToken,
        topic: String,
        replay: ConversationEventsReplayRequest,
        transcriptReplay: ConversationTranscriptSubscribeReplay,
        latestTotal: Int,
        latestMessage: Int,
        latestCheckpoint: Int
    ) async -> ReplayStatus {
        if transcriptReplay.forceLagging {
            return .laggingRequired
        }
        switch replay {
        case .totalOrderSince(let since):
            if let since, since > latestTotal { return .notRequested }
        case .dual(let sinceM, let sinceC):
            if let sm = sinceM, sm > latestMessage { return .laggingRequired }
            if let sc = sinceC, sc > latestCheckpoint { return .laggingRequired }
        }

        let lines = transcriptReplay.persistedReplayLines
        for json in lines {
            guard let line = HarnessOutboundWireLine.makeValidatedReplay(json: json, hubLabel: "ConversationEventsTopicHub", logger: logger) else { continue }
            noteWireSeq(from: line, topic: topic)
            await sendRawInProcess(token: token, json: line.json)
        }
        return lines.isEmpty ? .notRequested : .replayed
    }

    private func sendLagging(token: ConnectionToken, topic: String, seq: Int, resumeToken: String? = nil) async throws {
        let envelope = CommResourceTopicMessage<ConversationTopicEventPayload>(
            lagging: topic,
            seq: seq,
            hint: "resync",
            resumeToken: resumeToken,
            trustTag: .unknownRestricted
        )
        try await send(token: token, envelope: envelope)
    }

    private func mintResumeToken(
        conversationID: UUID,
        latestMessage: Int,
        latestCheckpoint: Int,
        latestTotal: Int
    ) -> String? {
        guard let secretRaw = resumeTokenHMACSecret else { return nil }
        let exp = Int(Date().timeIntervalSince1970) + ConversationEventsResumeToken.defaultTTLSeconds
        let payload = ConversationEventsResumeTokenPayload(
            v: ConversationEventsResumeTokenPayload.schemaVersion,
            conv: conversationID,
            msg: latestMessage,
            chk: latestCheckpoint,
            tot: latestTotal,
            exp: exp
        )
        return try? ConversationEventsResumeToken.mint(payload: payload, secret: Data(secretRaw.utf8))
    }

    private func trustTag(for payload: ConversationTopicEventPayload) -> CommEnvelopeTrustTag {
        if payload.semanticKind == .runtimeLifecycle,
           let jsonUTF8 = payload.jsonUTF8,
           let data = jsonUTF8.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let runtime = try? decoder.decode(RuntimeLifecycleEventPayload.self, from: data) {
                return CommEnvelopeTrustTag.fromSubAgentTrustRaw(runtime.originTrustLevel)
            }
        }
        guard payload.semanticKind == .messagesRefresh else {
            return .unknownRestricted
        }
        guard let jsonUTF8 = payload.jsonUTF8,
              let data = jsonUTF8.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]]
        else {
            return .unknownRestricted
        }

        let tags = messages.map { message in
            CommEnvelopeTrustTag.fromMessageInputTrustRaw(message["inputTrustRaw"] as? String)
        }
        return CommEnvelopeTrustTag.mostRestrictive(tags, fallback: .systemTrusted)
    }

    private func makeWireLine(_ envelope: CommResourceTopicMessage<ConversationTopicEventPayload>) -> HarnessOutboundWireLine? {
        HarnessOutboundWireLine.makeOrLog(from: envelope, hubLabel: "ConversationEventsTopicHub", logger: logger)
    }

    private func send(
        token: ConnectionToken,
        envelope: CommResourceTopicMessage<ConversationTopicEventPayload>
    ) async throws {
        guard let sub = subscribers[token] else { return }
        guard let line = makeWireLine(envelope) else { return }
        if let seq = envelope.seq {
            lastWireSeqByTopic[envelope.topic] = max(lastWireSeqByTopic[envelope.topic] ?? 0, seq)
        }
        logger?.debug(
            "ConversationEventsTopicHub send token=\(token.uuid.uuidString) topic=\(envelope.topic) kind=\(envelope.kind.rawValue) seq=\(envelope.seq ?? -1) bytes=\(line.json.utf8.count)"
        )
        try await sub.sendWireLine(line)
    }

    private func sendLine(token: ConnectionToken, line: HarnessOutboundWireLine) async throws {
        guard let sub = subscribers[token] else { return }
        try await sub.sendWireLine(line)
    }

    private func sendInProcess(
        token: EmbeddedTopicSubscriberToken,
        envelope: CommResourceTopicMessage<ConversationTopicEventPayload>
    ) async {
        guard let line = makeWireLine(envelope) else { return }
        if let seq = envelope.seq {
            lastWireSeqByTopic[envelope.topic] = max(lastWireSeqByTopic[envelope.topic] ?? 0, seq)
        }
        await sendRawInProcess(token: token, json: line.json)
    }

    private func sendRawInProcess(token: EmbeddedTopicSubscriberToken, json: String) async {
        guard let sub = inProcessSubscribers[token] else { return }
        await sub.sendJSON(json)
    }

    private func noteWireSeq(from line: HarnessOutboundWireLine, topic: String) {
        lastWireSeqByTopic[topic] = max(lastWireSeqByTopic[topic] ?? 0, line.seq)
    }

    private func fanOut(
        topic: String,
        envelope: CommResourceTopicMessage<ConversationTopicEventPayload>
    ) async {
        guard let line = makeWireLine(envelope) else { return }
        let wsSnapshot = subscribers
        let wsTargetCount = wsSnapshot.values.reduce(into: 0) { count, sub in
            if sub.topics.contains(topic) { count += 1 }
        }
        for (token, sub) in wsSnapshot where sub.topics.contains(topic) {
            do {
                try await sendLine(token: token, line: line)
            } catch {
                logger?.error("ConversationEventsTopicHub: send failed, dropping subscriber: \(error)")
                subscribers[token] = nil
            }
        }

        let ipcSnapshot = inProcessSubscribers
        let ipcTargetCount = ipcSnapshot.values.reduce(into: 0) { count, sub in
            if sub.topics.contains(topic) { count += 1 }
        }
        logger?.debug(
            "ConversationEventsTopicHub fanOut topic=\(topic) kind=\(envelope.kind.rawValue) seq=\(envelope.seq ?? -1) wsTargets=\(wsTargetCount) ipcTargets=\(ipcTargetCount) bytes=\(line.json.utf8.count)"
        )
        for (token, sub) in ipcSnapshot where sub.topics.contains(topic) {
            await sendRawInProcess(token: token, json: line.json)
        }
    }

    private func shouldPublish(payload: ConversationTopicEventPayload, topic: String) -> Bool {
        let issues = PublishingContractValidator.validateConversationEventPayload(payload)
        guard !issues.isEmpty else { return true }
        let detail = issues.joined(separator: "; ")
        if governance.diagnosticsEnabled || governance.rejectsInvalidPayloads {
            logger?.warning("ConversationEventsTopicHub publish contract validation failed [topic=\(topic), mode=\(governance.mode.rawValue)]: \(detail)")
        }
        return governance.rejectsInvalidPayloads == false
    }
}
