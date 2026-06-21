import Foundation

/// Multiplexed `/ws` harness outbound gate: credit windows keyed by topic with optional latest-wins coalescing for state-like feeds.
///
/// Only JSON objects whose top-level **`kind`** is `snapshot`, `event`, or `lagging`
/// participate.
actor WebSocketHarnessOutboundFlowLimiter {
    enum HarnessTopicFlowClass {
        case highFrequencyEvents
        case stateLike
    }

    private struct TopicBucket {
        var ackSeen = false
        var ackedUpTo = 0
        /// ``kind: event`` seqs written to the socket but not yet covered by ``ack`` (`seq <= ackedUpTo`).
        var inflight: [Int] = []
        var pendingLines: [HarnessOutboundWireLine] = []
        var pendingCoalesced: HarnessOutboundWireLine?
        var lastSeq = 0
        var lastFlowPressureNanos: UInt64 = 0
        var bufferedPendingBytes = 0
    }

    private let configuration: WebSocketOutboundFlowConfiguration
    private let wsSend: @Sendable (String) async throws -> Void
    private let requestDisconnect: @Sendable () async -> Void

    private var topics: [String: TopicBucket] = [:]

    init(
        configuration: WebSocketOutboundFlowConfiguration,
        wsSend: @escaping @Sendable (String) async throws -> Void,
        requestDisconnect: @escaping @Sendable () async -> Void
    ) {
        self.configuration = configuration
        self.wsSend = wsSend
        self.requestDisconnect = requestDisconnect
    }

    func sendHarnessLine(_ line: HarnessOutboundWireLine) async throws {
        guard configuration.enabled else {
            try await wsSend(line.json)
            return
        }

        if line.kind != .event {
            try await wsSend(line.json)
            var bucket = topics[line.topic] ?? TopicBucket()
            bucket.lastSeq = max(bucket.lastSeq, line.seq)
            topics[line.topic] = bucket
            return
        }

        var bucket = topics[line.topic] ?? TopicBucket()
        guard shouldApplyLimits(for: bucket, topic: line.topic) else {
            try await wsSend(line.json)
            bucket.lastSeq = max(bucket.lastSeq, line.seq)
            topics[line.topic] = bucket
            return
        }

        let cls = Self.flowClass(forHarnessTopic: line.topic)
        let cap = cls == .highFrequencyEvents ? configuration.maxInflightEvents : configuration.maxInflightStateLike

        if bucket.inflight.count < cap {
            try await wsSend(line.json)
            bucket.inflight.append(line.seq)
            bucket.lastSeq = max(bucket.lastSeq, line.seq)
            topics[line.topic] = bucket
            try await maybeEmitFlowPressure(topic: line.topic, cls: cls)
            await drain(topic: line.topic)
            return
        }

        let byteCount = line.json.utf8.count
        if cls == .stateLike, configuration.coalesceStateTopicsWhenOverCapacity {
            if let old = bucket.pendingCoalesced {
                bucket.bufferedPendingBytes -= old.json.utf8.count
            }
            bucket.pendingCoalesced = line
            bucket.bufferedPendingBytes += byteCount
        } else {
            bucket.pendingLines.append(line)
            bucket.bufferedPendingBytes += byteCount
        }
        topics[line.topic] = bucket

        await checkDisconnect(cls: cls, bucket: bucket)
        try await maybeEmitFlowPressure(topic: line.topic, cls: cls)
    }

    func applyAck(topic: String, upTo: Int) async {
        guard configuration.enabled else { return }
        guard var bucket = topics[topic] else {
            var fresh = TopicBucket()
            fresh.ackSeen = true
            fresh.ackedUpTo = upTo
            topics[topic] = fresh
            await drain(topic: topic)
            return
        }
        bucket.ackSeen = true
        if upTo < bucket.ackedUpTo {
            topics[topic] = bucket
            return
        }
        bucket.ackedUpTo = upTo
        bucket.inflight.removeAll { $0 <= upTo }
        topics[topic] = bucket
        await drain(topic: topic)
    }

    private func shouldApplyLimits(for bucket: TopicBucket, topic: String) -> Bool {
        guard configuration.enabled else { return false }
        if !configuration.limitOnlyAfterFirstAckPerTopic { return true }
        if bucket.ackSeen { return true }
        if configuration.applyLimitsToHighFrequencyEventsBeforeFirstAck,
           Self.flowClass(forHarnessTopic: topic) == .highFrequencyEvents {
            return true
        }
        return false
    }

    private func drain(topic: String) async {
        do {
            try await drainLoop(topic: topic)
        } catch {
            await requestDisconnect()
        }
    }

    private func drainLoop(topic: String) async throws {
        while true {
            let cls = Self.flowClass(forHarnessTopic: topic)
            let cap = cls == .highFrequencyEvents ? configuration.maxInflightEvents : configuration.maxInflightStateLike
            guard var bucket = topics[topic] else { return }
            guard bucket.inflight.count < cap else { return }

            let line: HarnessOutboundWireLine
            if let coalesced = bucket.pendingCoalesced {
                bucket.pendingCoalesced = nil
                bucket.bufferedPendingBytes -= coalesced.json.utf8.count
                line = coalesced
            } else if let first = bucket.pendingLines.first {
                bucket.pendingLines.removeFirst()
                bucket.bufferedPendingBytes -= first.json.utf8.count
                line = first
            } else {
                topics[topic] = bucket
                return
            }
            topics[topic] = bucket

            if line.kind != .event {
                try await wsSend(line.json)
                continue
            }

            try await wsSend(line.json)
            bucket = topics[topic] ?? TopicBucket()
            bucket.inflight.append(line.seq)
            bucket.lastSeq = max(bucket.lastSeq, line.seq)
            topics[topic] = bucket
        }
    }

    private func checkDisconnect(cls: HarnessTopicFlowClass, bucket: TopicBucket) async {
        if cls == .highFrequencyEvents,
           bucket.pendingLines.count >= configuration.disconnectPendingEventsThreshold {
            await requestDisconnect()
            return
        }
        let thresh = configuration.disconnectBufferedBytesThreshold
        guard thresh > 0 else { return }
        if bucket.bufferedPendingBytes >= thresh {
            await requestDisconnect()
        }
    }

    private func maybeEmitFlowPressure(topic: String, cls: HarnessTopicFlowClass) async throws {
        guard var bucket = topics[topic] else { return }
        let soft = cls == .highFrequencyEvents ? configuration.softInflightEvents : configuration.softInflightStateLike
        guard bucket.inflight.count >= soft else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        if bucket.lastFlowPressureNanos != 0,
           now &- bucket.lastFlowPressureNanos < configuration.flowPressureCooldownNanoseconds {
            return
        }
        bucket.lastFlowPressureNanos = now
        topics[topic] = bucket

        let seq = max(topics[topic]?.lastSeq ?? 1, 1)
        try await wsSend(Self.flowPressureLaggingJSON(topic: topic, seq: seq))
    }

    private static func flowPressureLaggingJSON(topic: String, seq: Int) -> String {
        #"{"kind":"lagging","topic":"\#(topic)","trustClass":"trusted","originTrust":"system","seq":\#(seq),"hint":"\#(HarnessWireHints.flowPressure)"}"#
    }

    private static func flowClass(forHarnessTopic topic: String) -> HarnessTopicFlowClass {
        if ConversationTopicFormat.parseConversationEventsTopic(topic) != nil {
            return .highFrequencyEvents
        }
        if SubAgentTopicFormat.parseEventsTopic(topic) != nil {
            return .highFrequencyEvents
        }
        if TraceTopicFormat.parseConversationTopic(topic) != nil || TraceTopicFormat.isServerTopic(topic) {
            return .highFrequencyEvents
        }
        return .stateLike
    }
}
