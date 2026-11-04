import Foundation
import Testing
@testable import SwiftAgentHarness

/// Approvals that hold every card until it is answered or withdrawn.
actor PendingComputerUseApprovals: ExecApprovalDelivering {
    private(set) var requests: [ExecApprovalRequest] = []
    private(set) var withdrawn: [String] = []

    func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        requests.append(request)
        try? await Task.sleep(for: .seconds(30))
        return .approved
    }

    func sendFollowup(approvalID: String, approved: Bool) async {
        if !approved { withdrawn.append(approvalID) }
    }
}

@Suite("Computer use session rules")
struct ComputerUseSessionRulesTests {
    private typealias S = ComputerUseSessionFixtures

    private let click = ComputerAction.click(at: .ref("e2", observation: "o_1"))
    private let type = ComputerAction.type(text: "hi", into: .ref("e5", observation: "o_1"))

    private func make(
        approvals: (any ExecApprovalDelivering)? = RecordingComputerUseApprovals(.approved),
        oversight: (any ComputerUseOversight)? = nil
    ) async throws -> (FakeDisplayTarget, ComputerUseSession) {
        let (target, session) = try await S.make(manifest: FakeDisplayTarget.vmManifest, approvals: approvals, oversight: oversight)
        _ = await session.perform([S.observe])
        return (target, session)
    }

    @Test("A signal on a whole call is confirmed once, on a card listing its actions and the model's stated intent")
    func callSignals() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await make(approvals: approvals)
        let result = await session.perform([click, type], callSignals: [.requireConfirmation], intents: [0: "Open the form", 1: "Fill it in"])
        #expect(result.outcomes.map(\.effect) == [.confirmed, .confirmed])
        #expect(result.signalsAcknowledged)
        let cards = await approvals.requests
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.description.contains("1. click"))
        #expect(card.description.contains("2. type"))
        #expect(card.description.contains("Model's stated intent (unverified): Fill it in"))
        #expect(await target.actCalls.count == 2)
        #expect(await session.auditLog.last?.statedIntent == "Fill it in")
    }

    @Test("A declined call runs none of its actions and isn't acknowledged")
    func callDeclined() async throws {
        let (target, session) = try await make(approvals: RecordingComputerUseApprovals(.denied("no")))
        let result = await session.perform([click, type], callSignals: [.maliciousInstructions])
        #expect(result.outcomes.map(\.effect) == [.refused, .notExecuted])
        #expect(!result.signalsAcknowledged)
        #expect(await target.actCalls.isEmpty)
    }

    @Test("A consequential action's card shows the model's stated intent, labeled as its claim")
    func statedIntentOnCard() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await make(approvals: approvals)
        let delete = ComputerAction.click(at: .ref("e8", observation: "o_1"))
        _ = await session.perform([delete], intents: [0: "Tidy up"])
        #expect(await approvals.requests.first?.description.contains("Model's stated intent (unverified): Tidy up") == true)
    }

    @Test("After the failure escalation, failing again before any progress ends the session as no-progress")
    func failuresAfterAsking() async throws {
        let (_, session) = try await S.make(manifest: FakeDisplayTarget.vmManifest, oversight: ScriptedComputerUseOversight(reply: "try the other menu"))
        let refused = ComputerAction.click(at: .ref("e2", observation: "o_404"))
        for _ in 0..<2 { _ = await session.perform([refused]) }
        let escalated = await session.perform([refused])
        #expect(escalated.escalation == .askUser)
        #expect(await session.terminalReason == nil)
        _ = await session.askUser("which menu?")
        for _ in 0..<2 { _ = await session.perform([refused]) }
        #expect(await session.terminalReason == nil, "the user's answer reset the count")
        _ = await session.perform([refused])
        #expect(await session.terminalReason == .noProgress)
    }

    @Test("An unanswered question ends the session needing the user, carrying the question")
    func questionTimesOut() async throws {
        actor Silent: ComputerUseOversight {
            func askUser(_ question: String) async -> ComputerUseUserReply { .timedOut }
            func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult { .timedOut }
        }
        let (_, session) = try await make(oversight: Silent())
        #expect(await session.askUser("Which account?") == .timedOut)
        #expect(await session.terminalReason == .needsUser)
        #expect(await session.unresolvedQuestion == "Which account?")
        let task = try ComputerUseTask(
            arguments: .object(["goal": .string("x"), "success_criteria": .string("done"), "apps": .string("com.apple.TextEdit:full")]),
            defaults: ComputerUseSpecialistDefaults(target: FakeDisplayTarget.vmManifest.id)
        )
        let result = ComputerUseResultBuilder.build(
            task: task, verifications: [], terminal: .needsUser, terminalDetail: "the user didn't answer",
            budget: ComputerUseResult.Budget(stepsUsed: 1, stepsGranted: 10, extensions: 0), child: .completed,
            unresolvedHandoff: nil, unresolvedQuestion: "Which account?", headlessDenials: [], finalText: nil, actionsLog: ""
        )
        #expect(result.status == .needsUser)
        #expect(result.handoff?.prompt == "Which account?")
    }

    @Test("Stopping a session withdraws the card it is waiting on")
    func stopWithdrawsCard() async throws {
        let approvals = PendingComputerUseApprovals()
        let (target, session) = try await make(approvals: approvals)
        let delete = ComputerAction.click(at: .ref("e8", observation: "o_1"))
        let waiting = Task { await session.perform([delete]) }
        for _ in 0..<200 where await approvals.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await session.stop()
        let result = await waiting.value
        #expect(result.outcomes.map(\.effect) == [.refused])
        #expect(await approvals.withdrawn.count == 1)
        #expect(await target.actCalls.isEmpty)
    }
}
