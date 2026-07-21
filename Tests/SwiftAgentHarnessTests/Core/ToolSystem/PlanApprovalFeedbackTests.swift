import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PlanApprovalFeedback")
struct PlanApprovalFeedbackTests {
    @Test("denied content includes revision directive and optional reason")
    func deniedWithReason() {
        let text = PlanApprovalFeedback.deniedToolResultContent(reason: "Needs clearer success criteria")
        #expect(text.contains("stay in plan mode"))
        #expect(text.contains("revise plan.md"))
        #expect(text.contains("exit_plan_mode"))
        #expect(text.contains("Needs clearer success criteria"))
    }

    @Test("denied content without reason is still structured")
    func deniedWithoutReason() {
        let text = PlanApprovalFeedback.deniedToolResultContent(reason: nil)
        #expect(text.contains("stay in plan mode"))
        #expect(text.contains("No revision note was provided"))
        #expect(text.contains("Tool dispatch denied.") == false)
    }
}
