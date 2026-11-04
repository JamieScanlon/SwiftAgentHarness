import EasyJSON
import Foundation
import SwiftAgentKit
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

@Suite("Computer use tool results: harness text and screen text")
struct ComputerUseResultEnvelopeTests {
    @Test("An observation's header and the reminder stay outside the envelope; the tree is inside")
    func observeSplit() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        let provider = ComputerUseToolProvider(session: session)
        let result = try await provider.executeTool(ToolCall(name: "computer_observe", arguments: .object([:]), id: "c1"))
        let content = result.content
        let start = try #require(content.range(of: "EXTERNAL_UNTRUSTED_CONTENT"))
        let outside = String(content[..<start.lowerBound])
        let inside = String(content[start.lowerBound...])
        #expect(outside.contains("Observation o_1"))
        #expect(!outside.contains("[e2]"))
        #expect(inside.contains("[e2]"))
        #expect(ToolExternalContentPolicy.resolve(toolName: "computer_observe", entry: nil).selfEnveloping)
        let rewrapped = ToolResultExternalContentMiddleware.apply(toolCall: ToolCall(name: "computer_observe", id: "c1"), result: result, entry: nil)
        #expect(rewrapped.content == content, "the middleware doesn't wrap the harness's text again")
    }

    @Test("Arguments outside a computer tool's schema are rejected")
    func unknownArguments() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        let provider = ComputerUseToolProvider(session: session)
        let result = try await provider.executeTool(ToolCall(name: "computer_observe", arguments: .object(["max_minutes": .integer(5)]), id: "c1"))
        #expect(!result.success)
        #expect(result.content.contains("max_minutes is not a parameter of computer_observe"))
        #expect(await target.observeCalls.isEmpty)
    }
}

@Suite("Computer use: wait-for conditions")
struct ComputerUseWaitForTests {
    private typealias S = ComputerUseSessionFixtures

    private func tree(_ elements: [ElementRef]) -> ObservationTree {
        ObservationTree(text: "", elements: Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) }), capturedAt: ComputerUseFixtures.epoch)
    }

    @Test("URL patterns use * as a wildcard; without one they match as a substring")
    func urlPatterns() {
        #expect(ComputerUseWaitEvaluator.matches("https://shop.example/cart?id=3", pattern: "https://shop.example/cart*"))
        #expect(ComputerUseWaitEvaluator.matches("https://shop.example/cart?id=3", pattern: "/cart"))
        #expect(!ComputerUseWaitEvaluator.matches("https://shop.example/home", pattern: "https://shop.example/cart*"))
        #expect(ComputerUseWaitEvaluator.matches("https://a.example/x/done", pattern: "*/done"))
    }

    @Test("An element condition is polled on fresh observations until it holds, and its observation is kept")
    func elementAppears() async throws {
        let (target, session) = try await S.make(manifest: FakeDisplayTarget.vmManifest)
        let plain = tree([ElementRef(id: "e1", role: "AXButton", label: "Save")])
        let sheet = tree([ElementRef(id: "e1", role: "AXButton", label: "Save"), ElementRef(id: "e2", role: "AXSheet", label: "Saved")])
        await target.setTrees([plain, plain, plain, sheet])
        _ = await session.perform([S.observe])
        let result = await session.perform([.waitFor(condition: .element(.appears, role: "AXSheet"), timeoutMilliseconds: 5_000)])
        let outcome = try #require(result.outcomes.first)
        #expect(outcome.effect == .confirmed, "\(outcome.evidence ?? "")")
        #expect(outcome.evidence?.contains("element AXSheet appears") == true)
        let kept = try #require(outcome.observation)
        #expect(await session.observation(kept)?.tree?.elements.values.contains { $0.role == "AXSheet" } == true)
        #expect(await target.actCalls.isEmpty, "the session evaluates, nothing is sent to the driver")
    }

    @Test("A value condition reads the cited element's value; a timeout is partial")
    func valueAndTimeout() async throws {
        let (target, session) = try await S.make(manifest: FakeDisplayTarget.vmManifest)
        let field = ElementRef(id: "e1", role: "AXTextField", label: "Status", value: "Pending")
        await target.setTrees([tree([field]), tree([field])])
        _ = await session.perform([S.observe])
        let result = await session.perform([.waitFor(condition: .value(.equals, ref: "e1", text: "Paid"), timeoutMilliseconds: 300)])
        #expect(result.outcomes.first?.effect == .partial)
        #expect(result.outcomes.first?.evidence?.contains("did not happen within 300 ms") == true)
    }

    @Test("A condition the target can't show is a bounded wait and an observation, and says so")
    func unevaluable() async throws {
        let (_, session) = try await S.make(manifest: FakeDisplayTarget.vmManifest)
        _ = await session.perform([S.observe])
        let started = ContinuousClock.now
        let result = await session.perform([.waitFor(condition: .url(pattern: "/done"), timeoutMilliseconds: 50)])
        let outcome = try #require(result.outcomes.first)
        #expect(outcome.effect == .unverifiable)
        #expect(outcome.evidence?.contains("can't evaluate url matches /done here") == true)
        #expect(outcome.observation != nil)
        #expect(ContinuousClock.now - started >= .milliseconds(50))
    }

    @Test("The tool takes a structured condition and refuses prose")
    func toolArguments() async throws {
        let (_, session) = try await S.make(manifest: FakeDisplayTarget.vmManifest)
        let provider = ComputerUseToolProvider(session: session)
        let prose = try await provider.executeTool(ToolCall(name: "computer_wait_for", arguments: .object(["kind": .string("the dialog closes")]), id: "c1"))
        #expect(!prose.success)
        #expect(prose.content.contains("isn't a wait-for kind"))
        let settles = try await provider.executeTool(ToolCall(
            name: "computer_wait_for",
            arguments: .object(["kind": .string("screen-settles"), "quiet_ms": .integer(100), "timeout_ms": .integer(2_000)]),
            id: "c2"
        ))
        #expect(settles.content.hasPrefix("wait-for: confirmed"), "\(settles.content.prefix(300))")
    }
}

@Suite("Computer use session: the target's own events")
struct ComputerUseSessionTargetEventTests {
    private static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test("The target's stop key ends the session as the kill switch")
    func stopKey() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        await session.announceStart()
        target.eventHub.post(.stopRequested)
        #expect(await Self.eventually { await session.terminalReason == .killSwitch })
        #expect(await target.releases == [.killSwitch])
    }

    @Test("A permission the target lost ends the session; one it still has doesn't")
    func permissionChange() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        await session.announceStart()
        let required = FakeDisplayTarget.vmManifest.requires
        target.eventHub.post(.permissionsChanged(PermissionSnapshot(states: Dictionary(uniqueKeysWithValues: required.map { ($0, .granted) }))))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await session.terminalReason == nil)
        guard let first = required.first else { return }
        target.eventHub.post(.permissionsChanged(PermissionSnapshot(states: [first: .denied])))
        #expect(await Self.eventually { await session.terminalReason == .permissionRevoked })
    }

    @Test("A takeover the user starts at the target pauses the agent until they end it there")
    func targetTakeover() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        await session.announceStart()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        target.eventHub.post(.takeoverChanged(on: true))
        #expect(await Self.eventually { await session.isTakeoverActive })
        let paused = await session.perform([.click(at: .ref("e2", observation: "o_1"))])
        #expect(paused.outcomes.first?.effect == .refused)
        target.eventHub.post(.takeoverChanged(on: false))
        #expect(await Self.eventually { await !session.isTakeoverActive })
        #expect(await target.takeoverStates.isEmpty, "the target already knows")
    }

    @Test("While the user types on a shared desktop, the agent's input waits and observing still works")
    func userTyping() async throws {
        let clock = ComputerUseTestClock()
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest, clock: clock)
        await session.announceStart()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let steps = await session.stepCount
        target.eventHub.post(.userTyping)
        try await Task.sleep(for: .milliseconds(30))
        let waited = await session.perform([.click(at: .ref("e2", observation: "o_1")), .key(combo: KeyCombo(modifiers: [], key: "tab"))])
        #expect(waited.outcomes.map(\.effect) == [.notExecuted, .notExecuted])
        #expect(waited.outcomes.first?.escalation == .observe)
        #expect(waited.outcomes.first?.evidence?.contains("typing") == true)
        #expect(await session.stepCount == steps, "input that waited took no step")
        #expect(await session.perform([ComputerUseSessionFixtures.observe]).outcomes.first?.effect == .confirmed)
        clock.advance(seconds: ComputerUseSession.userTypingQuiet + 0.5)
        let resumed = await session.perform([.click(at: .ref("e2", observation: "o_2"))])
        #expect(resumed.outcomes.first?.effect == .confirmed, "\(resumed.outcomes)")
        #expect(await target.actCalls.count == 1)
    }
}

@Suite("Computer use session: secrets kept from helper models")
struct ComputerUseSessionSecretTests {
    @Test("Values typed during takeover, held by one-time-code fields, or typed into password fields are known secrets")
    func knownSecrets() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        await session.announceStart()
        await target.setTrees([ObservationTree(
            text: "window",
            elements: [
                "e1": ElementRef(id: "e1", role: "textbox", label: "Code", inputPurpose: "one-time-code", value: "482913"),
                "e2": ElementRef(id: "e2", role: "textbox", label: "Password", isSecureInput: true),
                "e3": ElementRef(id: "e3", role: "textbox", label: "Name", value: "Ada Lovelace"),
            ],
            capturedAt: ComputerUseFixtures.epoch
        )])
        _ = await session.perform([.observe(ObserveRequest(modes: [.accessibility], scope: .display(nil)))])
        #expect(await session.knownSecrets() == ["482913"])

        _ = await session.perform([.type(text: "correct horse", into: .ref("e2", observation: "o_1"))])
        target.eventHub.post(.typedDuringTakeover("p@ssw0rd!"))
        for _ in 0..<100 where await session.knownSecrets().count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(Set(await session.knownSecrets()) == ["482913", "correct horse", "p@ssw0rd!"])

        let redacted = ComputerUseSecrets.redacting("Is the code 482913 or p@ssw0rd! visible? Ada Lovelace", known: await session.knownSecrets())
        #expect(redacted == "Is the code [redacted] or [redacted] visible? Ada Lovelace")
        #expect(ComputerUseSecrets.redacting("pin 12", known: ["12"]) == "pin 12", "values too short to redact safely are left")
        #expect(ComputerUseSecrets.probeInput("code 482913", source: .screen, known: ["482913"]) == "code [redacted]")
    }
}
