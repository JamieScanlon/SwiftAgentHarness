import EasyJSON
import Foundation
import SwiftAgentKit
import Synchronization
import Testing
@testable import SwiftAgentHarness

final class ComputerUseTestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = ComputerUseFixtures.epoch) {
        current = Mutex(start)
    }

    func now() -> Date { current.withLock { $0 } }

    func advance(seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

actor RecordingComputerUseApprovals: ExecApprovalDelivering {
    private let answer: ExecApprovalDeliveryResult
    private(set) var requests: [ExecApprovalRequest] = []

    init(_ answer: ExecApprovalDeliveryResult) {
        self.answer = answer
    }

    func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        requests.append(request)
        return headless ? .headlessDenied("headless") : answer
    }

    func sendFollowup(approvalID: String, approved: Bool) async {}
}

actor ScriptedComputerUseOversight: ComputerUseOversight {
    private(set) var questions: [String] = []
    private(set) var handoffs: [ComputerUseHandoffRequest] = []
    private let reply: String?

    init(reply: String? = "yes") {
        self.reply = reply
    }

    func askUser(_ question: String) async -> ComputerUseUserReply {
        questions.append(question)
        return reply.map(ComputerUseUserReply.answered) ?? .unavailable
    }

    func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult {
        handoffs.append(request)
        return .handedBack(note: "logged in")
    }
}

enum ComputerUseSessionFixtures {
    static let grants: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .full)]

    static func intentDispatcher(verdict: DecisionVerdict) -> RecordingGateDispatcher {
        RecordingGateDispatcher { _ in
            DecisionOutcome(
                result: DecisionResult(
                    modelVersion: "guard-v1",
                    calibrated: true,
                    guarantee: .calibratedDistribution,
                    answers: [ComputerUseIntentCheckConfiguration.questionID: .yesNo(pYes: verdict == .act ? 0.99 : 0.2)],
                    usage: DecisionUsage(inputTokens: 50)
                ),
                evaluation: DecisionEvaluation(verdict: verdict, reason: .band(verdict), modelVersion: "guard-v1"),
                receipt: RouteReceipt(role: .guardrail, contract: .decide, requested: "guard")
            )
        }
    }

    static func unboundDispatcher() -> RecordingGateDispatcher {
        RecordingGateDispatcher { _ in
            DecisionOutcome(
                result: nil,
                evaluation: DecisionEvaluation(verdict: .confirm, reason: .error, modelVersion: nil),
                receipt: RouteReceipt(role: .guardrail, contract: .decide, requested: "guard"),
                error: .roleUnbound(.guardrail)
            )
        }
    }

    static func checker(_ dispatcher: RecordingGateDispatcher) -> ComputerUseIntentChecker {
        ComputerUseIntentChecker(
            dispatcher: dispatcher,
            configuration: ComputerUseIntentCheckConfiguration(
                policy: DecisionFixtures.gatePolicy(versions: ["guard-v1"], question: ComputerUseIntentCheckConfiguration.questionID)
            )
        )
    }

    static func make(
        manifest: DisplayTargetManifest = FakeDisplayTarget.hostManifest,
        grants: [ComputerUseGrant] = grants,
        userPresent: Bool = true,
        budgets: ComputerUseBudgets = ComputerUseBudgets(steps: 100, noProgressSteps: 100, maxDuration: .seconds(3600)),
        approvals: (any ExecApprovalDelivering)? = nil,
        intentChecker: ComputerUseIntentChecker? = nil,
        oversight: (any ComputerUseOversight)? = nil,
        overrides: ComputerUseOperatorOverrides = .none,
        clock: ComputerUseTestClock = ComputerUseTestClock(),
        successCriteria: [String] = [],
        storeApprovalImage: (@Sendable (Data) async -> String?)? = nil,
        confirmsInteract: Bool = false,
        modePolicy: (@Sendable () async -> ComputerUseModePolicy)? = nil,
        returnSchema: JSON? = nil,
        activity: (@Sendable (ComputerUseActivity) async -> Void)? = nil
    ) async throws -> (FakeDisplayTarget, ComputerUseSession) {
        let target = FakeDisplayTarget(manifest: manifest, now: { clock.now() })
        let lease = try await target.lease(LeaseRequest(
            target: manifest.id,
            agentID: "agent",
            grants: grants,
            budgets: budgets,
            initiator: .operator,
            userPresent: userPresent
        ))
        var configuration = ComputerUseSessionConfiguration(
            task: ComputerUseTaskContext(
                userRequest: ["Make the first line bold and save the document."],
                successCriteria: successCriteria,
                returnSchema: returnSchema
            ),
            classifier: ComputerUseActionClassifier(reviewer: ComputerUseGrantReviewer(overrides: overrides))
        )
        configuration.storeApprovalImage = storeApprovalImage
        configuration.confirmsInteract = confirmsInteract
        configuration.modePolicy = modePolicy
        let session = ComputerUseSession(
            target: target,
            lease: lease,
            configuration: configuration,
            approvals: approvals,
            intentChecker: intentChecker,
            oversight: oversight,
            activity: activity,
            now: { clock.now() }
        )
        return (target, session)
    }

    static let observe = ComputerAction.observe(ObserveRequest(modes: [.pixels, .accessibility], scope: .display(nil)))
}

@Suite("Computer use session gating")
struct ComputerUseSessionGatingTests {
    private static func downloadFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func file(_ name: String, in folder: URL, disposable: Bool = true) throws -> DisplayDownload {
        let path = folder.appendingPathComponent(name).path
        try Data(name.utf8).write(to: URL(fileURLWithPath: path))
        return DisplayDownload(name: name, path: path, completed: true, disposable: disposable)
    }

    @Test("A finish naming paths outside the download folder, or downloads that don't exist, is rejected once")
    func finishValidatesKeepFiles() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        let folder = try Self.downloadFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let invoice = try Self.file("invoice.pdf", in: folder)
        await target.setDownloads([invoice])
        let first = await session.finish(result: "Saved.", keepFiles: ["invoice.pdf", "../outside.txt", invoice.path, "missing.txt"])
        #expect(!first.accepted)
        #expect(first.problems.contains("keep_files ../outside.txt: not a path inside the download folder"))
        #expect(first.problems.contains("keep_files \(invoice.path): not a path inside the download folder"), "only relative paths")
        #expect(first.problems.contains("keep_files missing.txt: nothing was downloaded by that name"))
        #expect(await session.finishRejection == first.problems)
        #expect(await !session.hasFinished)
        let second = await session.finish(result: "Saved.", keepFiles: ["invoice.pdf", "../outside.txt"])
        #expect(second.accepted, "the last try commits what is valid")
        #expect(await session.finishedResult == "Saved.")
        #expect(await session.finishRejection == nil)
        #expect(await !session.finish(result: "Again.", keepFiles: []).accepted, "one commit only")
    }

    @Test("A finish result that doesn't match the return schema is rejected once, then committed for the builder to drop")
    func finishValidatesResult() async throws {
        let schema: JSON = .object(["type": .string("object"), "required": .array([.string("saved")])])
        let (_, session) = try await ComputerUseSessionFixtures.make(returnSchema: schema)
        let first = await session.finish(result: "I saved it.", keepFiles: [])
        #expect(!first.accepted)
        #expect(first.problems.first?.hasPrefix("result ") == true, "\(first.problems)")
        #expect(await session.finish(result: #"{"saved": true}"#, keepFiles: []).accepted)
        #expect(await session.finishedResult == #"{"saved": true}"#)
    }

    @Test("At the end every download is listed; named files become attachments, a managed browser's others are deleted")
    func finalizeDownloads() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        let folder = try Self.downloadFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let invoice = try Self.file("invoice.pdf", in: folder)
        let stray = try Self.file("tracker.bin", in: folder)
        let users = try Self.file("user.zip", in: folder, disposable: false)
        let usersNamed = try Self.file("statement.csv", in: folder, disposable: false)
        await target.setDownloads([invoice, stray, users, usersNamed])
        #expect(await session.finish(result: "Saved.", keepFiles: ["invoice.pdf", "statement.csv"]).accepted)
        await session.end()
        let moved = Mutex<[String: Data]>([:])
        let listed = await session.finalizeDownloads { download, data in
            moved.withLock { $0[download.name] = data }
            return "blob-\(download.name)"
        }
        #expect(listed == [
            ComputerUseResult.Download(name: "invoice.pdf", bytes: 11, kept: true, attachment: "blob-invoice.pdf"),
            ComputerUseResult.Download(name: "tracker.bin", bytes: 11, kept: false),
            ComputerUseResult.Download(name: "user.zip", bytes: 8, kept: true),
            ComputerUseResult.Download(name: "statement.csv", bytes: 13, kept: true, attachment: "blob-statement.csv"),
        ])
        #expect(moved.withLock { $0["invoice.pdf"] } == Data("invoice.pdf".utf8))
        #expect(!FileManager.default.fileExists(atPath: invoice.path), "a managed browser's kept file moves")
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: users.path), "the user's browser's files stay where they are")
        #expect(FileManager.default.fileExists(atPath: usersNamed.path), "and a named one is copied, not moved")
    }

    @Test("Without a finish nothing of a managed browser's is kept, whatever the report says")
    func noFinishKeepsNothing() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        let folder = try Self.downloadFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let invoice = try Self.file("invoice.pdf", in: folder)
        await target.setDownloads([invoice])
        await session.end()
        let listed = await session.finalizeDownloads(moving: nil)
        #expect(listed == [ComputerUseResult.Download(name: "invoice.pdf", bytes: 11, kept: false)])
        #expect(!FileManager.default.fileExists(atPath: invoice.path))
    }

    @Test("A named file over the attachment cap isn't copied, and a managed browser's stays in its folder")
    func overTheCap() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        let folder = try Self.downloadFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let invoice = try Self.file("invoice.pdf", in: folder)
        await target.setDownloads([invoice])
        #expect(await session.finish(result: "Saved.", keepFiles: ["invoice.pdf"]).accepted)
        await session.end()
        let listed = await session.finalizeDownloads(attachmentLimit: 4) { _, _ in
            Issue.record("a file over the cap is never read")
            return nil
        }
        #expect(listed == [ComputerUseResult.Download(name: "invoice.pdf", bytes: 11, kept: true)])
        #expect(FileManager.default.fileExists(atPath: invoice.path))
    }

    @Test("The finish tool commits, or reports why it was rejected so the specialist can call it again")
    func finishTool() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        let folder = try Self.downloadFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await target.setDownloads([try Self.file("invoice.pdf", in: folder)])
        let provider = ComputerUseToolProvider(session: session)
        let rejected = try await provider.executeTool(ToolCall(
            name: ComputerUseToolProvider.finishToolName,
            arguments: .object(["result": .string("Saved."), "keep_files": .array([.string("invoice.pdf"), .string("../x")])]),
            id: "f1"
        ))
        #expect(!rejected.success)
        #expect(rejected.content.contains("keep_files ../x: not a path inside the download folder"), "\(rejected.content)")
        let accepted = try await provider.executeTool(ToolCall(
            name: ComputerUseToolProvider.finishToolName,
            arguments: .object(["result": .string("Saved."), "keep_files": .array([.string("invoice.pdf")])]),
            id: "f2"
        ))
        #expect(accepted.success)
        #expect(accepted.content == "Finished.")
        let noResult = try await provider.executeTool(ToolCall(name: ComputerUseToolProvider.finishToolName, arguments: .object([:]), id: "f3"))
        #expect(!noResult.success)
    }

    @Test("Observations run without approval and are retained for citing")
    func observeRetained() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make()
        let result = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(result.outcomes.first?.observation == "o_1")
        #expect(result.observations.map(\.id) == ["o_1"])
        #expect(await session.observation("o_1") != nil)
    }

    @Test("An out-of-grant action is refused with its reason and the rest of the batch is not executed")
    func outOfGrantStopsBatch() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([
            .openURL("file:///etc/passwd"),
            .click(at: .ref("e2", observation: "o_1")),
        ])
        #expect(result.outcomes.map(\.effect) == [.refused, .notExecuted])
        #expect(result.outcomes[0].evidence?.contains("http(s)") == true)
        #expect(await target.actCalls.isEmpty)
    }

    @Test("Citing an observation that is not retained is refused with an observe escalation")
    func staleObservation() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        let result = await session.perform([.click(at: .ref("e2", observation: "o_missing"))])
        #expect(result.outcomes.first?.effect == .refused)
        #expect(result.outcomes.first?.escalation == .observe)
    }

    @Test("With no intent checker, interact actions on a shared target are confirmed through the approval surface")
    func sharedTargetConfirmsWithoutChecker() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await ComputerUseSessionFixtures.make(approvals: approvals)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        let requests = await approvals.requests
        #expect(requests.count == 1)
        #expect(requests.first?.allowsDurableBypass == false)
        #expect(requests.first?.command.contains("click") == true)
        #expect(await target.actCalls.count == 1)
    }

    @Test("A user denial refuses the action and nothing reaches the target")
    func userDenial() async throws {
        let approvals = RecordingComputerUseApprovals(.denied("no"))
        let (target, session) = try await ComputerUseSessionFixtures.make(approvals: approvals)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1")), .wait(milliseconds: 10)])
        #expect(result.outcomes.map(\.effect) == [.refused, .notExecuted])
        #expect(await target.actCalls.isEmpty)
        #expect(result.records.first?.decision == .userDenied)
    }

    @Test("With no intent checker, interact actions on an unshared VM run without confirmation")
    func vmAllowsWithoutChecker() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest, approvals: approvals)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await approvals.requests.isEmpty)
    }

    @Test("An explicit operator opt-out skips interact confirmation on shared targets")
    func operatorOptOut() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await ComputerUseSessionFixtures.make(
            approvals: approvals,
            overrides: ComputerUseOperatorOverrides(skipInteractConfirmationWithoutIntentCheck: true)
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(await approvals.requests.isEmpty)
    }

    @Test("A mode that requires confirming Interact confirms it on a target that otherwise wouldn't")
    func modeConfirmsInteract() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            approvals: approvals,
            confirmsInteract: true
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(result.records.first?.decision == .confirmed)
        let request = try #require(await approvals.requests.first)
        #expect(request.description.contains("Why confirm: this conversation's mode requires confirming every interact action"))
        #expect(await target.actCalls.count == 1)
    }

    @Test("A mode's Interact confirmation holds even when the intent check agrees, and leaves observing alone")
    func modeConfirmsOverConsistentIntent() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            approvals: approvals,
            intentChecker: ComputerUseSessionFixtures.checker(ComputerUseSessionFixtures.intentDispatcher(verdict: .act)),
            confirmsInteract: true
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(await approvals.requests.isEmpty, "observing is not interacting")
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(await approvals.requests.count == 1)
    }

    @Test("A mode's Interact confirmation can't be skipped by the operator's opt-out")
    func modeConfirmsOverOperatorOptOut() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await ComputerUseSessionFixtures.make(
            approvals: approvals,
            overrides: ComputerUseOperatorOverrides(skipInteractConfirmationWithoutIntentCheck: true),
            confirmsInteract: true
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(await approvals.requests.count == 1)
    }

    @Test("With nobody present, a mode's Interact confirmation refuses the action as headless")
    func modeConfirmsHeadless() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            userPresent: false,
            approvals: approvals,
            confirmsInteract: true
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(result.records.first?.decision == .headlessDenied)
        #expect(await approvals.requests.isEmpty)
        #expect(await target.actCalls.isEmpty)
    }

    @Test("A mode that starts requiring Interact confirmation mid-session reaches the next action, and loosening it later doesn't")
    func modeTightensMidSession() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let policy = Mutex(ComputerUseModePolicy())
        let (_, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            approvals: approvals,
            modePolicy: { policy.withLock { $0 } }
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(await approvals.requests.isEmpty, "the modes start out ordinary")
        policy.withLock { $0.confirmsInteract = true }
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(await approvals.requests.count == 1)
        policy.withLock { $0.confirmsInteract = false }
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(await approvals.requests.count == 2, "a looser mode waits for the next session")
    }

    @Test("A mode that starts denying computer use ends the session before its next action")
    func modeDeniesMidSession() async throws {
        let policy = Mutex(ComputerUseModePolicy())
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            modePolicy: { policy.withLock { $0 } }
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        policy.withLock { $0.denied = true }
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(result.outcomes.first?.effect == .notExecuted)
        #expect(result.terminal == .policyRevoked)
        #expect(await target.actCalls.isEmpty)
        #expect(await target.releases == [.policyRevoked])
    }

    @Test("A denial arriving while an action runs lets it finish, and the rest of the batch isn't executed")
    func modeDeniesMidBatch() async throws {
        let policy = Mutex(ComputerUseModePolicy())
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            modePolicy: { policy.withLock { $0 } }
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        await target.setOutcomes { _, index in
            policy.withLock { $0.denied = true }
            return ActionOutcome(action: index, effect: .confirmed, evidence: "fake")
        }
        let click = ComputerAction.click(at: .ref("e2", observation: "o_1"))
        let result = await session.perform([click, click])
        #expect(result.outcomes.map(\.effect) == [.confirmed, .notExecuted])
        #expect(result.terminal == .policyRevoked)
        #expect(await target.actCalls.count == 1)
    }

    @Test("A consistent intent verdict allows interact actions; the check never sees screen text")
    func intentConsistentAllows() async throws {
        let dispatcher = ComputerUseSessionFixtures.intentDispatcher(verdict: .act)
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await ComputerUseSessionFixtures.make(
            approvals: approvals,
            intentChecker: ComputerUseSessionFixtures.checker(dispatcher)
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await approvals.requests.isEmpty)

        let requests = await dispatcher.requests
        #expect(requests.count == 1)
        #expect(await dispatcher.roles == [.guardrail])
        let state = String(describing: requests[0].state)
        #expect(state.contains("AXButton"))
        #expect(state.contains("com.apple.TextEdit"))
        #expect(!state.contains("Bold"))
        #expect(!state.contains("obs="))
    }

    @Test("A mismatched intent verdict routes to confirmation, never silently allowed")
    func intentMismatchConfirms() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            approvals: approvals,
            intentChecker: ComputerUseSessionFixtures.checker(ComputerUseSessionFixtures.intentDispatcher(verdict: .confirm))
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(await approvals.requests.count == 1)
    }

    @Test("An unbound guard role falls back to the no-checker rule")
    func unboundChecker() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await ComputerUseSessionFixtures.make(
            approvals: approvals,
            intentChecker: ComputerUseSessionFixtures.checker(ComputerUseSessionFixtures.unboundDispatcher())
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(await approvals.requests.count == 1)
    }

    @Test("Consequential actions are confirmed even when the intent check agrees, and the card carries the verdict")
    func consequentialAlwaysConfirms() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            approvals: approvals,
            intentChecker: ComputerUseSessionFixtures.checker(ComputerUseSessionFixtures.intentDispatcher(verdict: .act))
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.press(at: .ref("e8", observation: "o_1"))])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        let request = try #require(await approvals.requests.first)
        let text = request.presentation.textFallback(approvalID: request.id)
        #expect(text.contains("consistent with the task"))
        #expect(text.contains("Delete account"))
        #expect(!request.presentation.buttons.contains { $0.id == ApprovalDecision.allowAlways.rawValue })
    }

    @Test("Headless consequential actions are denied without asking anyone")
    func headlessDenied() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            userPresent: false,
            approvals: approvals
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.press(at: .ref("e8", observation: "o_1"))])
        #expect(result.outcomes.map(\.effect) == [.refused])
        #expect(result.records.first?.decision == .headlessDenied)
        #expect(await approvals.requests.isEmpty)
        #expect(await target.actCalls.isEmpty)
        #expect(await session.headlessDenials.count == 1)
    }

    @Test("Confirmation is per action inside a batch: a refusal stops the batch after earlier actions ran")
    func perActionConfirmationInBatch() async throws {
        let approvals = RecordingComputerUseApprovals(.denied("not that"))
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest, approvals: approvals)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([
            .click(at: .ref("e5", observation: "o_1")),
            .type(text: "Quarterly report", into: .ref("e5", observation: "o_1")),
            .press(at: .ref("e8", observation: "o_1")),
            .click(at: .ref("e6", observation: "o_1")),
        ])
        #expect(result.outcomes.map(\.effect) == [.confirmed, .confirmed, .refused, .notExecuted])
        #expect(result.outcomes.map(\.action) == [0, 1, 2, 3])
        #expect(await target.actCalls.count == 2)
        #expect(await approvals.requests.count == 1)
    }

    @Test("A failing driver outcome stops the batch; nothing after it is sent")
    func driverFailureStopsBatch() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        await target.setOutcomes { action, index in
            ActionOutcome(action: index, effect: action.kind == .click ? .suspectedNoop : .confirmed, evidence: "no visual change")
        }
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1")), .key(combo: try KeyCombo(parsing: "cmd+s"))])
        #expect(result.outcomes.map(\.effect) == [.suspectedNoop, .notExecuted])
        #expect(await target.actCalls.count == 1)
    }

    @Test("A driver error after sending is unverifiable, escalates to observe, and is never retried")
    func driverErrorUnverifiable() async throws {
        let target = ThrowingDisplayTarget()
        let lease = Lease(
            request: LeaseRequest(
                target: target.manifest.id, agentID: "agent", grants: ComputerUseSessionFixtures.grants,
                budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(600)), initiator: .operator, userPresent: true
            ),
            issuedAt: ComputerUseFixtures.epoch
        )
        let session = ComputerUseSession(
            target: target,
            lease: lease,
            configuration: ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["x"])),
            now: { ComputerUseFixtures.epoch }
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1")), .wait(milliseconds: 1)])
        #expect(result.outcomes.map(\.effect) == [.unverifiable, .notExecuted])
        #expect(result.outcomes[0].escalation == .observe)
        #expect(await target.actCount == 1)
    }

    @Test("A script on a shared target is shown to the user whole; the command and the log keep only its hash")
    func scriptApproval() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await ComputerUseSessionFixtures.make(approvals: approvals)
        let source = "document.querySelector('#title').textContent = 'Draft';"
        let result = await session.perform([.script(language: .javascript, source: source, timeoutMilliseconds: 2_000)])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        let request = try #require(await approvals.requests.first)
        #expect(request.description.contains(source))
        #expect(request.description.contains("a script on a target someone is using"))
        #expect(!request.command.contains("textContent"))
        #expect(await session.auditLog.allSatisfy { !$0.canonical.contains("textContent") })
        #expect(await target.actCalls.count == 1)
    }

    @Test("Audit records carry classification and decision but never the typed text")
    func auditRecords() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let result = await session.perform([.type(text: "s3cret-token", into: .ref("e5", observation: "o_1"))])
        let record = try #require(result.records.first)
        #expect(record.actionClass == "interact")
        #expect(record.decision == .allowed)
        #expect(record.observations == ["o_1"])
        #expect(!record.canonical.contains("s3cret-token"))
        #expect(record.canonical.contains("sha256:"))
        #expect(record.binding.count == 64)
        #expect(await session.auditLog.count == 2)
    }
}

@Suite("Computer use session budgets, kill switch, and oversight")
struct ComputerUseSessionLifecycleTests {
    @Test("The step budget ends the session with a typed reason and releases the lease")
    func stepBudget() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            budgets: ComputerUseBudgets(steps: 2, maxDuration: .seconds(3600))
        )
        let result = await session.perform([
            ComputerUseSessionFixtures.observe,
            .wait(milliseconds: 1),
            .wait(milliseconds: 1),
        ])
        #expect(result.outcomes.map(\.effect) == [.confirmed, .confirmed, .notExecuted])
        #expect(result.terminal == .stepBudget)
        #expect(await session.terminalReason == .stepBudget)
        #expect(await target.releases == [.budgetExhausted])
    }

    @Test("Actions the driver reports as not executed don't use up steps")
    func notExecutedNotCounted() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            budgets: ComputerUseBudgets(steps: 1, maxDuration: .seconds(3600))
        )
        await target.setOutcomes { _, index in ActionOutcome(action: index, effect: .notExecuted) }
        for _ in 0..<3 {
            #expect(await session.perform([.wait(milliseconds: 1)]).outcomes.map(\.effect) == [.notExecuted])
        }
        #expect(await session.stepCount == 0)
        #expect(await session.terminalReason == nil)
    }

    @Test("The wall-clock budget ends the session")
    func timeBudget() async throws {
        let clock = ComputerUseTestClock()
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            budgets: ComputerUseBudgets(steps: 100, maxDuration: .seconds(60)),
            clock: clock
        )
        clock.advance(seconds: 61)
        let result = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(result.outcomes.map(\.effect) == [.notExecuted])
        #expect(result.terminal == .timeBudget)
        #expect(await target.releases == [.expired])
    }

    @Test("The cost budget ends the session once recorded spend exceeds it")
    func costBudget() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            budgets: ComputerUseBudgets(steps: 100, maxDuration: .seconds(3600), maxUSD: 1)
        )
        await session.recordCost(usd: 0.6)
        #expect(await session.terminalReason == nil)
        await session.recordCost(usd: 0.6)
        #expect(await session.terminalReason == .costBudget)
        #expect(await target.releases == [.budgetExhausted])
    }

    @Test("Revoking a platform permission mid-session ends it before the next batch")
    func permissionRevoked() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        await target.setPermission(.accessibility, .denied)
        let result = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(result.outcomes.map(\.effect) == [.notExecuted])
        #expect(result.terminal == .permissionRevoked)
        #expect(await target.releases == [.permissionRevoked])
    }

    @Test("The kill switch ends the session once; later batches are not executed")
    func killSwitch() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        await session.stop()
        await session.stop()
        #expect(await session.terminalReason == .killSwitch)
        #expect(await target.releases == [.killSwitch])
        let result = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(result.outcomes.map(\.effect) == [.notExecuted])
        #expect(await target.observeCalls.isEmpty)
    }

    @Test("Repeated failures escalate to ask-user instead of looping")
    func repeatedFailuresEscalate() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        var last: ComputerUseBatchResult?
        for _ in 0..<3 {
            last = await session.perform([.click(at: .ref("e2", observation: "o_missing"))])
        }
        #expect(last?.escalation == .askUser)
        let recovered = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(recovered.escalation == nil)
    }

    @Test("Handoff turns takeover on for the human step and off afterwards")
    func handoff() async throws {
        let oversight = ScriptedComputerUseOversight()
        let (target, session) = try await ComputerUseSessionFixtures.make(oversight: oversight)
        let result = await session.handoff(reason: .login, prompt: "Please sign in to the account.")
        #expect(result == .handedBack(note: "logged in"))
        #expect(await target.takeoverStates == [true, false])
        #expect(await oversight.handoffs.map(\.reason) == [.login])
        #expect(await session.isTakeoverActive == false)
    }

    @Test("Takeover blocks agent input and capture until the human hands back")
    func takeoverBlocks() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        try await session.setTakeover(true)
        let result = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(result.outcomes.map(\.effect) == [.refused])
        #expect(await target.observeCalls.isEmpty)
        try await session.setTakeover(false)
        #expect(await session.perform([ComputerUseSessionFixtures.observe]).outcomes.map(\.effect) == [.confirmed])
    }

    @Test("Ask-user and handoff are unavailable without a present user")
    func unattendedOversight() async throws {
        let oversight = ScriptedComputerUseOversight()
        let (_, session) = try await ComputerUseSessionFixtures.make(
            manifest: FakeDisplayTarget.vmManifest,
            userPresent: false,
            oversight: oversight
        )
        #expect(await session.askUser("Which file?") == .unavailable)
        #expect(await session.handoff(reason: .captcha, prompt: "Solve it") == .unavailable)
        #expect(await oversight.questions.isEmpty)
    }

    @Test("Verification needs an observation taken after the last action")
    func verifyNeedsFreshObservation() async throws {
        let clock = ComputerUseTestClock()
        let (_, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest, clock: clock)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        clock.advance(seconds: 1)
        _ = await session.perform([.click(at: .ref("e6", observation: "o_1"))])
        await #expect(throws: ComputerUseSessionError.staleVerification("o_1")) {
            try await session.verify(criterion: "document saved", met: true, evidence: "title has no dot", observation: "o_1")
        }
        clock.advance(seconds: 1)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        try await session.verify(criterion: "document saved", met: true, evidence: "title has no dot", observation: "o_2")
        #expect(await session.verifications.map(\.criterion) == ["document saved"])
    }

    @Test("Waiting does not count as an action for verification freshness")
    func waitKeepsObservationFresh() async throws {
        let clock = ComputerUseTestClock()
        let (_, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest, clock: clock)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        clock.advance(seconds: 1)
        _ = await session.perform([.wait(milliseconds: 500), .waitFor(condition: .element(.disappears, role: "AXSheet"), timeoutMilliseconds: 1000)])
        try await session.verify(criterion: "dialog closed", met: true, evidence: "no sheet in tree", observation: "o_1")
    }
}

/// Throws from `act` after the action may have been delivered.
actor ThrowingDisplayTarget: DisplayTarget {
    nonisolated let manifest = FakeDisplayTarget.vmManifest
    private(set) var actCount = 0

    func lease(_ request: LeaseRequest) async throws -> Lease { Lease(request: request, issuedAt: ComputerUseFixtures.epoch) }
    func release(_ lease: Lease, reason: ReleaseReason) async {}
    func permissions() async -> PermissionSnapshot { PermissionSnapshot(states: [:]) }
    func describe(_ lease: Lease) async throws -> TargetLayout { TargetLayout(displays: [], focusedApp: ComputerUseFixtures.textEdit) }
    func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        ComputerUseFixtures.observation(id: "o_1")
    }
    func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        actCount += 1
        throw DisplayTargetError.driverFailure("connection reset")
    }
    func takeover(_ lease: Lease, on: Bool) async throws {}
}
