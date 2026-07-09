import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ToolCallApprovalBinding")
struct ToolCallApprovalBindingTests {
    @Test("fingerprint is stable regardless of object key order")
    func fingerprintStableKeyOrder() {
        let a = ToolCallApprovalBinding.argumentsFingerprint(arguments: .object([
            "path": .string("/tmp/a"),
            "mode": .string("write"),
        ]))
        let b = ToolCallApprovalBinding.argumentsFingerprint(arguments: .object([
            "mode": .string("write"),
            "path": .string("/tmp/a"),
        ]))
        #expect(a == b)
    }

    @Test("distinct arguments produce distinct fingerprints")
    func distinctArguments() {
        let a = ToolCallApprovalBinding.from(
            toolName: "write_file",
            arguments: .object(["path": .string("/a")])
        )
        let b = ToolCallApprovalBinding.from(
            toolName: "write_file",
            arguments: .object(["path": .string("/b")])
        )
        #expect(a != b)
    }

    @Test("matches call using canonical tool name")
    func matchesCallCanonicalName() {
        let binding = ToolCallApprovalBinding.from(
            toolName: "read_file",
            arguments: .object(["path": .string("x")])
        )
        let call = ToolCallRequest(
            id: "c1",
            name: "READ",
            arguments: .object(["path": .string("x")])
        )
        #expect(binding.matches(call: call))
    }

    @Test("rejects approve-then-swap when arguments change")
    func rejectsArgumentSwap() {
        let binding = ToolCallApprovalBinding.from(
            toolName: "write_file",
            arguments: .object(["path": .string("/approved")])
        )
        let swapped = ToolCallRequest(
            id: "same-id",
            name: "write_file",
            arguments: .object(["path": .string("/other")])
        )
        #expect(binding.matches(call: swapped) == false)
    }
}
