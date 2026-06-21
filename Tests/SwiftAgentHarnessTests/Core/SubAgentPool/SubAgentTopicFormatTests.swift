import Foundation
import Testing
@testable import SwiftAgentHarness

struct SubAgentTopicFormatTests {
    @Test func buildsAndParsesNestedBranchEventTopic() {
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let topic = SubAgentTopicFormat.eventsTopic(
            conversationID: cid,
            pathSegments: ["agent-0", "agent-2"]
        )
        #expect(topic == "subagent/\(cid.uuidString.lowercased())/agent-0/agent-2/events")

        let parsed = SubAgentTopicFormat.parseEventsTopic(topic)
        #expect(parsed?.conversationID == cid)
        #expect(parsed?.pathSegments == ["agent-0", "agent-2"])
        #expect(parsed?.kind == .events)
    }

    @Test func parseRejectsLegacyThreeSegmentShape() {
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let legacy = "subagent/\(cid.uuidString.lowercased())/events"
        #expect(SubAgentTopicFormat.parse(legacy) == nil)
        #expect(SubAgentTopicFormat.parseEventsTopic(legacy) == nil)
    }

    @Test func replayCapacityRoutesOnlyNewSubAgentPathShape() {
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var cfg = TopicReplayCapacityConfiguration.default
        cfg.subAgentLifecycleEvents = 9
        let valid = "subagent/\(cid.uuidString.lowercased())/agent-0/state"
        let legacy = "subagent/\(cid.uuidString.lowercased())/state"
        #expect(cfg.capacity(for: valid) == 9)
        #expect(cfg.capacity(for: legacy) == 0)
    }
}
