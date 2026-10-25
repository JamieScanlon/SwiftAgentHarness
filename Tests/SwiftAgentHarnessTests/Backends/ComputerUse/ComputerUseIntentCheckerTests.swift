import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use intent check")
struct ComputerUseIntentCheckerTests {
    private let proposed = ComputerUseProposedAction(kind: "click", app: "com.apple.TextEdit", elementRole: "AXButton")

    @Test("An act verdict is consistent; confirm, refuse, and errors all route to confirmation")
    func interpretation() async {
        for (verdict, consistent) in [(DecisionVerdict.act, true), (.confirm, false), (.refuse, false)] {
            let checker = ComputerUseSessionFixtures.checker(ComputerUseSessionFixtures.intentDispatcher(verdict: verdict))
            let result = await checker.evaluate(ComputerUseIntentCheckInput(userRequest: ["bold it"], history: [], proposed: proposed))
            if case .consistent = result { #expect(consistent) } else { #expect(!consistent) }
        }
        let failing = ComputerUseSessionFixtures.checker(RecordingGateDispatcher.failing())
        guard case .confirm = await failing.evaluate(ComputerUseIntentCheckInput(userRequest: ["x"], history: [], proposed: proposed)) else {
            Issue.record("a failed check must confirm")
            return
        }
    }

    @Test("An unbound guard role reports unbound, not consistent")
    func unbound() async {
        let checker = ComputerUseSessionFixtures.checker(ComputerUseSessionFixtures.unboundDispatcher())
        guard case .unbound = await checker.evaluate(ComputerUseIntentCheckInput(userRequest: ["x"], history: [], proposed: proposed)) else {
            Issue.record("expected unbound")
            return
        }
    }

    @Test("With no user request there is nothing to check against, so it confirms without a call")
    func emptyRequest() async {
        let dispatcher = ComputerUseSessionFixtures.intentDispatcher(verdict: .act)
        let checker = ComputerUseSessionFixtures.checker(dispatcher)
        guard case .confirm = await checker.evaluate(ComputerUseIntentCheckInput(userRequest: ["  "], history: [], proposed: proposed)) else {
            Issue.record("expected confirm")
            return
        }
        #expect(await dispatcher.requests.isEmpty)
    }

    @Test("The request carries the task, a bounded action history, and harness identifiers in one yes-no question")
    func requestShape() throws {
        let history = (0..<15).map { ComputerUseProposedAction(kind: "click", app: "app.\($0)", elementRole: "AXButton") }
        let request = ComputerUseIntentChecker.makeRequest(userRequest: ["bold it"], history: Array(history.suffix(10)), proposed: proposed)
        #expect(request.questions.map(\.id) == [ComputerUseIntentCheckConfiguration.questionID])
        guard case .object(let state) = request.state, case .array(let prior)? = state["prior_actions"] else {
            Issue.record("unexpected state shape")
            return
        }
        #expect(prior.count == 10)
        #expect(String(describing: state["proposed_action"]).contains("AXButton"))
    }
}
