import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Approve/deny slash registry")
struct ApprovalSlashRegistryTests {
    @Test("builtins register both /approve and /deny as local commands")
    func registersApproveAndDeny() {
        let registry = SlashCommandRegistry.builtins(compactEnabled: true)
        let approve = registry.resolve("approve")
        let deny = registry.resolve("deny")
        #expect(approve != nil)
        #expect(deny != nil)
        if case .local = approve?.kind {} else { Issue.record("approve should be .local") }
        if case .local = deny?.kind {} else { Issue.record("deny should be .local") }
    }

    @Test("dispatcher routes /deny to a local builtin")
    func dispatchesDeny() {
        let dispatcher = SlashCommandDispatcher(registry: .builtins(compactEnabled: true))
        let result = dispatcher.dispatch(input: "/deny abc reason text", runtimeConfig: SlashCommandRuntimeConfiguration())
        guard case let .local(command, parsed) = result else {
            Issue.record("Expected .local dispatch for /deny")
            return
        }
        #expect(command.base.name == "deny")
        #expect(parsed.args == "abc reason text")
    }
}

@Suite("Exec approval inbound resolver")
struct ExecApprovalInboundTests {
    @Test("allow-always button grants a durable approval")
    func allowAlwaysGrantsDurable() async {
        let grants = InMemoryExecApprovalGrantStore()
        let store = ExecApprovalStore(grantStore: grants)
        await store.registerPending(id: "i1", command: "git push origin main")
        let resolution = await ExecApprovalInbound.resolve(approvalID: "i1", actionID: "allowAlways", store: store)
        #expect(resolution == .approved(durable: true))
        #expect(await grants.isGranted(commandName: "git"))
    }

    @Test("allow-once button approves without persisting")
    func allowOnceApproves() async {
        let grants = InMemoryExecApprovalGrantStore()
        let store = ExecApprovalStore(grantStore: grants)
        await store.registerPending(id: "i2", command: "ls -la")
        let resolution = await ExecApprovalInbound.resolve(approvalID: "i2", actionID: "allowOnce", store: store)
        #expect(resolution == .approved(durable: false))
        #expect(await grants.list().isEmpty)
    }

    @Test("deny button denies with reason")
    func denyButton() async {
        let store = ExecApprovalStore()
        await store.registerPending(id: "i3", command: "rm -rf /")
        let resolution = await ExecApprovalInbound.resolve(approvalID: "i3", actionID: "deny", store: store, reason: "nope")
        #expect(resolution == .denied("nope"))
    }

    @Test("unknown action token resolves to nil")
    func unknownToken() async {
        let store = ExecApprovalStore()
        await store.registerPending(id: "i4", command: "echo hi")
        let resolution = await ExecApprovalInbound.resolve(approvalID: "i4", actionID: "wat", store: store)
        #expect(resolution == nil)
    }
}

@Suite("ClientSurfaceIntent carries portable presentation")
struct ClientSurfaceIntentPresentationTests {
    @Test("execApprovalRequired intent round-trips presentation through JSON")
    func roundTripsPresentation() throws {
        let intent = ClientSurfaceIntent(
            kind: .execApprovalRequired,
            label: "Approve shell command?",
            approvalID: "x1",
            command: "npm test",
            presentation: .standard(title: "Approve shell command?", context: ["npm test"])
        )
        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(ClientSurfaceIntent.self, from: data)
        #expect(decoded == intent)
        #expect(decoded.presentation?.buttons.count == 3)
    }

    @Test("execApprovalCleared intent round-trips through JSON")
    func roundTripsClearedIntent() throws {
        let intent = ClientSurfaceIntent(kind: .execApprovalCleared, approvalID: "x1")
        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(ClientSurfaceIntent.self, from: data)
        #expect(decoded == intent)
        #expect(decoded.kind == .execApprovalCleared)
        #expect(decoded.approvalID == "x1")
    }
}
