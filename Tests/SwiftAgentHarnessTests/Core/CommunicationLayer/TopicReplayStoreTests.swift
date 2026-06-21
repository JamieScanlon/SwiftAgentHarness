import Foundation
import Testing
@testable import SwiftAgentHarness

/// Unit tests for bounded per-topic replay storage used by topic hubs.
struct TopicReplayStoreTests {
    private let topic = "conversation/00000000-0000-0000-0000-000000000001/events"

    @Test func replayRangeReturnsContiguousEvents() {
        var store = TopicReplayStore()
        store.append(topic: topic, seq: 1, json: #"{"a":1}"#, capacity: 16)
        store.append(topic: topic, seq: 2, json: #"{"a":2}"#, capacity: 16)
        store.append(topic: topic, seq: 3, json: #"{"a":3}"#, capacity: 16)

        let replay = store.replayRange(topic: topic, fromExclusive: 0, toInclusive: 3)
        #expect(replay == [#"{"a":1}"#, #"{"a":2}"#, #"{"a":3}"#])
    }

    @Test func replayRangeReturnsNilWhenGapInBuffer() {
        var store = TopicReplayStore()
        store.append(topic: topic, seq: 2, json: #"{"a":2}"#, capacity: 16)
        store.append(topic: topic, seq: 3, json: #"{"a":3}"#, capacity: 16)

        let replay = store.replayRange(topic: topic, fromExclusive: 0, toInclusive: 3)
        #expect(replay == nil)
    }

    @Test func replayRangeReturnsEmptyWhenNothingToReplay() {
        var store = TopicReplayStore()
        store.append(topic: topic, seq: 1, json: #"{"a":1}"#, capacity: 16)

        let replay = store.replayRange(topic: topic, fromExclusive: 1, toInclusive: 1)
        #expect(replay == [])
    }

    @Test func capacityEvictsOldestFirstBreakingReplayFromZero() {
        var store = TopicReplayStore()
        store.append(topic: topic, seq: 1, json: #"{"a":1}"#, capacity: 2)
        store.append(topic: topic, seq: 2, json: #"{"a":2}"#, capacity: 2)
        store.append(topic: topic, seq: 3, json: #"{"a":3}"#, capacity: 2)

        let replay = store.replayRange(topic: topic, fromExclusive: 0, toInclusive: 3)
        #expect(replay == nil)
    }

    @Test func duplicateSeqReplacesLastEntry() {
        var store = TopicReplayStore()
        store.append(topic: topic, seq: 1, json: #"{"v":1}"#, capacity: 8)
        store.append(topic: topic, seq: 1, json: #"{"v":2}"#, capacity: 8)

        let replay = store.replayRange(topic: topic, fromExclusive: 0, toInclusive: 1)
        #expect(replay == [#"{"v":2}"#])
    }

    @Test func capacityZeroClearsTopic() {
        var store = TopicReplayStore()
        store.append(topic: topic, seq: 1, json: #"{"a":1}"#, capacity: 8)
        store.append(topic: topic, seq: 2, json: #"{"a":2}"#, capacity: 0)

        let replay = store.replayRange(topic: topic, fromExclusive: 0, toInclusive: 2)
        #expect(replay == nil)
    }

    @Test func topicReplayCapacityConfigurationRoutesConversationEventsTopic() {
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let t = ConversationTopicFormat.topic(conversationID: cid)
        var cfg = TopicReplayCapacityConfiguration.default
        cfg.conversationEvents = 42
        #expect(cfg.capacity(for: t) == 42)
    }
}
