import Foundation
import Testing
@testable import SwiftAgentHarness

struct TraceTopicFormatTests {
    @Test func buildsAndParsesConversationTraceTopic() {
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let topic = TraceTopicFormat.conversationTopic(conversationID: cid)
        #expect(topic == "trace/\(cid.uuidString.lowercased())")
        #expect(TraceTopicFormat.parseConversationTopic(topic) == cid)
        #expect(TraceTopicFormat.isServerTopic(topic) == false)
    }

    @Test func parsesServerTraceTopic() {
        #expect(TraceTopicFormat.isServerTopic(TraceTopicFormat.serverTopic))
        #expect(TraceTopicFormat.parseConversationTopic(TraceTopicFormat.serverTopic) == nil)
    }

    @Test func replayCapacityRoutesTraceTopics() {
        var cfg = TopicReplayCapacityConfiguration.default
        cfg.traceConversationEvents = 17
        cfg.traceServerEvents = 9
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(cfg.capacity(for: TraceTopicFormat.conversationTopic(conversationID: cid)) == 17)
        #expect(cfg.capacity(for: TraceTopicFormat.serverTopic) == 9)
    }
}
