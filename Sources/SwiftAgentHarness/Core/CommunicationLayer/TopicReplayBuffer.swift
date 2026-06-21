import Foundation

// MARK: - Bounded replay (Communication Layer)
//
// Subscribe `since` is the last processed per-topic `seq`. On subscribe, hubs replay contiguous
// buffered `event` JSON lines for `(since … latestSeq]` when the ring retains that range; otherwise
// they emit `lagging` then `snapshot`. Snapshots are never buffered.

/// Per-topic replay capacities for communication-layer event streams.
///
/// Capacities are count-based (number of event envelopes retained per topic string).
/// `0` disables replay retention for that topic class.
public struct TopicReplayCapacityConfiguration: Sendable, Equatable {
    public var modelStateEvents: Int
    public var poolHealthEvents: Int
    public var modelsRegistryEvents: Int
    public var conversationEvents: Int
    public var conversationStateEvents: Int
    public var capabilityRegistryEvents: Int
    public var conversationsRegistryEvents: Int
    public var subAgentLifecycleEvents: Int
    public var traceConversationEvents: Int
    public var traceServerEvents: Int

    public init(
        modelStateEvents: Int = 256,
        poolHealthEvents: Int = 64,
        modelsRegistryEvents: Int = 128,
        conversationEvents: Int = 1024,
        conversationStateEvents: Int = 256,
        capabilityRegistryEvents: Int = 128,
        conversationsRegistryEvents: Int = 128,
        subAgentLifecycleEvents: Int = 256,
        traceConversationEvents: Int = 512,
        traceServerEvents: Int = 256
    ) {
        self.modelStateEvents = max(0, modelStateEvents)
        self.poolHealthEvents = max(0, poolHealthEvents)
        self.modelsRegistryEvents = max(0, modelsRegistryEvents)
        self.conversationEvents = max(0, conversationEvents)
        self.conversationStateEvents = max(0, conversationStateEvents)
        self.capabilityRegistryEvents = max(0, capabilityRegistryEvents)
        self.conversationsRegistryEvents = max(0, conversationsRegistryEvents)
        self.subAgentLifecycleEvents = max(0, subAgentLifecycleEvents)
        self.traceConversationEvents = max(0, traceConversationEvents)
        self.traceServerEvents = max(0, traceServerEvents)
    }

    public static let `default` = TopicReplayCapacityConfiguration()

    public func capacity(for topic: String) -> Int {
        if topic == ResourceTopicName.poolHealth {
            return poolHealthEvents
        }
        if topic == ResourceTopicName.modelsRegistry {
            return modelsRegistryEvents
        }
        if topic == ResourceTopicName.toolsRegistry
            || topic == ResourceTopicName.skillsRegistry
            || topic == ResourceTopicName.subAgentsRegistry
        {
            return capabilityRegistryEvents
        }
        if topic == ResourceTopicName.conversationsRegistry {
            return conversationsRegistryEvents
        }
        if ModelStateTopicFormat.parseModelStateTopic(topic) != nil {
            return modelStateEvents
        }
        if ConversationTopicFormat.parseConversationEventsTopic(topic) != nil {
            return conversationEvents
        }
        if ConversationTopicFormat.parseConversationStateTopic(topic) != nil {
            return conversationStateEvents
        }
        if SubAgentTopicFormat.parseEventsTopic(topic) != nil
            || SubAgentTopicFormat.parseStateTopic(topic) != nil
        {
            return subAgentLifecycleEvents
        }
        if TraceTopicFormat.parseConversationTopic(topic) != nil {
            return traceConversationEvents
        }
        if TraceTopicFormat.isServerTopic(topic) {
            return traceServerEvents
        }
        return 0
    }
}

private struct TopicReplayEntry: Sendable {
    let seq: Int
    let json: String
}

/// Bounded in-memory replay store keyed by topic string.
struct TopicReplayStore: Sendable {
    private var entriesByTopic: [String: [TopicReplayEntry]] = [:]

    mutating func append(topic: String, seq: Int, json: String, capacity: Int) {
        guard capacity > 0 else {
            entriesByTopic[topic] = nil
            return
        }
        var entries = entriesByTopic[topic] ?? []
        if let last = entries.last, seq <= last.seq {
            if seq == last.seq {
                entries[entries.count - 1] = TopicReplayEntry(seq: seq, json: json)
                entriesByTopic[topic] = entries
            }
            return
        }
        entries.append(TopicReplayEntry(seq: seq, json: json))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        entriesByTopic[topic] = entries
    }

    /// Returns contiguous replay rows for `(fromExclusive, toInclusive]` when fully available.
    /// Returns `nil` when any sequence in the requested range is missing.
    func replayRange(topic: String, fromExclusive: Int, toInclusive: Int) -> [String]? {
        guard toInclusive > fromExclusive else { return [] }
        guard let entries = entriesByTopic[topic], !entries.isEmpty else { return nil }

        var cursor = 0
        var expectedSeq = fromExclusive + 1
        while cursor < entries.count, entries[cursor].seq < expectedSeq {
            cursor += 1
        }

        var replay: [String] = []
        replay.reserveCapacity(toInclusive - fromExclusive)

        while expectedSeq <= toInclusive {
            guard cursor < entries.count else { return nil }
            let entry = entries[cursor]
            guard entry.seq == expectedSeq else { return nil }
            replay.append(entry.json)
            expectedSeq += 1
            cursor += 1
        }
        return replay
    }
}
