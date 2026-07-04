import Foundation
import Testing
@testable import SwiftAgentHarness

/// Legacy WebSocket client `type` frames are rejected at validation before any server I/O.
@Suite("APILayer WebSocket migration errors")
struct APILayerWebSocketMigrationErrorTests {
    private static let legacyOps: [String] = [
        "send_message",
        "send_trigger_message",
        "list_conversations",
        "select_conversation",
        "create_conversation",
        "copy_conversation",
        "revert_to_message",
        "split_conversation",
        "stop_agent_build",
        "delete_conversation",
        "patch_conversation",
        "spawn_sub_agent",
        "resolve_tool_approval",
        "push_completion_announce",
    ]

    @Test("Legacy type frames require harness kind")
    func legacyTypeFramesRequireKind() {
        for op in Self.legacyOps {
            let obj: [String: Any] = ["type": op, "id": UUID().uuidString]
            let err = WebSocketCommClientControlValidator.validationError(jsonObject: obj)
            #expect(err == "Harness control message requires kind", "op=\(op)")
        }
    }

    @Test("Unknown legacy type is rejected the same way")
    func unknownLegacyTypeRejected() {
        let obj: [String: Any] = ["type": "unknown_type"]
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: obj) == "Harness control message requires kind")
    }

    @Test("Non-object JSON root is rejected")
    func nonObjectRootRejected() {
        #expect(WebSocketCommClientControlValidator.validationError(jsonObject: "not-an-object")
            == "Harness control message must be a JSON object")
    }

    @Test("Unknown harness kind is rejected")
    func unknownHarnessKindRejected() {
        let obj: [String: Any] = ["kind": "peek", "topic": "pool/health"]
        let err = WebSocketCommClientControlValidator.validationError(jsonObject: obj)
        #expect(err?.contains("subscribe") == true)
    }
}
