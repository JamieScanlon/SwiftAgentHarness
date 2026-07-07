import EasyJSON
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationHarnessMetadataKeys")
struct ConversationHarnessMetadataKeysTests {
    @Test("strippingClientControlledKeys removes sub-agent lineage keys")
    func strippingRemovesSubAgentKeys() {
        let incoming: JSON = .object([
            "subAgentRootConversationID": .string("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            "subAgentDepth": .integer(1),
            "userNote": .string("allowed"),
        ])
        let stripped = ConversationHarnessMetadataKeys.strippingClientControlledKeys(from: incoming)
        guard case .object(let object) = stripped else {
            Issue.record("Expected object metadata")
            return
        }
        #expect(object["subAgentRootConversationID"] == nil)
        #expect(object["subAgentDepth"] == nil)
        #expect(object["userNote"] != nil)
    }

    @Test("mergingPreservingHarnessKeys strips forged incoming keys and keeps existing harness keys")
    func mergePreservesExistingHarnessKeys() {
        let existing: JSON = .object([
            "subAgentRootConversationID": .string("11111111-1111-1111-1111-111111111111"),
            "subAgentDepth": .integer(2),
        ])
        let incoming: JSON = .object([
            "subAgentRootConversationID": .string("22222222-2222-2222-2222-222222222222"),
            "topicTag": .string("client"),
        ])
        let merged = ConversationHarnessMetadataKeys.mergingPreservingHarnessKeys(
            existing: existing,
            incoming: incoming
        )
        guard case .object(let object) = merged else {
            Issue.record("Expected object metadata")
            return
        }
        #expect(object["subAgentRootConversationID"]?.literalValue as? String == "11111111-1111-1111-1111-111111111111")
        #expect(object["subAgentDepth"]?.literalValue as? Int == 2)
        #expect(object["topicTag"]?.literalValue as? String == "client")
    }
}
