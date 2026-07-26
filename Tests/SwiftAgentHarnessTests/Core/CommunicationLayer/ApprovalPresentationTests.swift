import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Approval presentation and decision vocabulary")
struct ApprovalPresentationTests {
    @Test("presentation round-trips through JSON with the spec block shape")
    func presentationRoundTrips() throws {
        let presentation = ApprovalPresentation(blocks: [
            .text("Run command outside the sandbox?"),
            .context("rm -rf ./build  (destructive)"),
            .buttons(ApprovalButton.standardDecisionButtons()),
        ])
        let data = try JSONEncoder().encode(presentation)
        let decoded = try JSONDecoder().decode(ApprovalPresentation.self, from: data)
        #expect(decoded == presentation)
    }

    @Test("blocks encode with a type discriminator")
    func blocksEncodeWithType() throws {
        let data = try JSONEncoder().encode(ApprovalBlock.context("cmd"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "context")
        #expect(object?["text"] as? String == "cmd")
    }

    @Test("buttons accessor flattens button blocks")
    func buttonsAccessor() {
        let presentation = ApprovalPresentation(blocks: [
            .text("title"),
            .buttons([ApprovalButton(id: "allowOnce", label: "Allow once")]),
        ])
        #expect(presentation.buttons.count == 1)
        #expect(presentation.buttons.first?.id == "allowOnce")
    }

    @Test("plan exit decision buttons are Approve and Request revision only")
    func planExitButtons() {
        let buttons = ApprovalButton.planExitDecisionButtons()
        #expect(buttons.map(\.id) == [
            ApprovalDecision.allowOnce.rawValue,
            ApprovalDecision.deny.rawValue,
        ])
        #expect(buttons.map(\.label) == ["Approve", "Request revision"])
        #expect(buttons.contains(where: { $0.id == ApprovalDecision.allowAlways.rawValue }) == false)
    }

    @Test("standard decision buttons map to the unified vocabulary")
    func standardButtons() {
        let ids = ApprovalButton.standardDecisionButtons().map(\.id)
        #expect(ids == [
            ApprovalDecision.allowOnce.rawValue,
            ApprovalDecision.allowAlways.rawValue,
            ApprovalDecision.deny.rawValue,
        ])
    }

    @Test("standard factory skips blank context lines and appends buttons")
    func standardFactory() {
        let presentation = ApprovalPresentation.standard(
            title: "Approve shell command?",
            context: ["rm -rf ./build", "", "   "]
        )
        // text + one non-blank context + buttons
        #expect(presentation.blocks.count == 3)
        #expect(presentation.buttons.count == 3)
        if case .context(let value) = presentation.blocks[1] {
            #expect(value == "rm -rf ./build")
        } else {
            Issue.record("Expected a context block at index 1")
        }
    }

    @Test("text fallback carries justification plus approve and deny commands")
    func textFallback() {
        let presentation = ApprovalPresentation.standard(
            title: "Approve shell command?",
            context: ["npm test"]
        )
        let text = presentation.textFallback(approvalID: "abc")
        #expect(text.contains("Approve shell command?"))
        #expect(text.contains("npm test"))
        #expect(text.contains("/approve abc"))
        #expect(text.contains("/deny abc"))
    }
}

@Suite("Approval decision mapping")
struct ApprovalDecisionTests {
    @Test("isAllowed and persistsRule reflect the spec semantics")
    func allowedAndPersistence() {
        #expect(ApprovalDecision.allowOnce.isAllowed)
        #expect(ApprovalDecision.allowAlways.isAllowed)
        #expect(ApprovalDecision.allowAlways.persistsRule)
        #expect(ApprovalDecision.allowOnce.persistsRule == false)
        #expect(ApprovalDecision.deny.isAllowed == false)
        #expect(ApprovalDecision.timeout.isAllowed == false)
        #expect(ApprovalDecision.cancelled.isAllowed == false)
    }

    @Test("fromToken parses canonical values and aliases")
    func fromToken() {
        #expect(ApprovalDecision.fromToken("approve") == .allowOnce)
        #expect(ApprovalDecision.fromToken("allow-once") == .allowOnce)
        #expect(ApprovalDecision.fromToken("durable") == .allowAlways)
        #expect(ApprovalDecision.fromToken("always") == .allowAlways)
        #expect(ApprovalDecision.fromToken(" Deny ") == .deny)
        #expect(ApprovalDecision.fromToken("reject") == .deny)
        #expect(ApprovalDecision.fromToken("cancel") == .cancelled)
        #expect(ApprovalDecision.fromToken("nonsense") == nil)
    }

    @Test("exec resolution bridges onto the unified vocabulary")
    func execResolutionBridge() {
        #expect(ExecApprovalResolution.approved(durable: false).approvalDecision == .allowOnce)
        #expect(ExecApprovalResolution.approved(durable: true).approvalDecision == .allowAlways)
        #expect(ExecApprovalResolution.denied("x").approvalDecision == .deny)
    }

    @Test("tool status bridges both directions")
    func toolStatusBridge() {
        #expect(ToolApprovalResolutionStatus(decision: .allowOnce) == .approved)
        #expect(ToolApprovalResolutionStatus(decision: .allowAlways) == .approved)
        #expect(ToolApprovalResolutionStatus(decision: .deny) == .denied)
        #expect(ToolApprovalResolutionStatus(decision: .timeout) == .denied)
        #expect(ToolApprovalResolutionStatus(decision: .cancelled) == .denied)
        #expect(ApprovalDecision(toolStatus: .approved) == .allowOnce)
        #expect(ApprovalDecision(toolStatus: .denied) == .deny)
        #expect(ApprovalDecision(toolStatus: .pending) == nil)
    }
}
