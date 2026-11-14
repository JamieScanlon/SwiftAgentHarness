import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use safety signals and watch mode")
struct ComputerUseWatchModeTests {
    static let browserManifest = DisplayTargetManifest(
        id: "fake-browser",
        label: "Fake browser",
        platform: "chromium",
        isolation: .container,
        perception: [.dom, .pixels],
        delivery: [.background],
        semanticActions: [.press, .setValue, .openURL],
        observerAccess: .stream,
        humanPresence: .exclusive
    )

    actor ActivityLog {
        private(set) var statuses: [ComputerUseSurfaceIntentPayload.Status] = []
        func record(_ activity: ComputerUseActivity) { statuses.append(activity.status) }
    }

    private func make(
        manifest: DisplayTargetManifest = Self.browserManifest,
        userPresent: Bool = true,
        approvals: RecordingComputerUseApprovals = RecordingComputerUseApprovals(.approved),
        log: ActivityLog = ActivityLog(),
        wait: Duration = .seconds(5)
    ) async throws -> (FakeDisplayTarget, ComputerUseSession) {
        let target = FakeDisplayTarget(manifest: manifest, now: { Date() })
        await target.setObserved(app: ComputerUseFixtures.textEdit, url: "https://bank.example/")
        let lease = try await target.lease(LeaseRequest(
            target: manifest.id,
            agentID: "agent",
            grants: [.domain("bank.example", tier: .full), .app(bundleID: ComputerUseFixtures.textEdit.bundleID, tier: .full)],
            budgets: ComputerUseBudgets(steps: 100, noProgressSteps: 100, maxDuration: .seconds(3600)),
            initiator: .operator,
            userPresent: userPresent
        ))
        var configuration = ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["Pay the bill."]))
        configuration.watchModeWait = wait
        configuration.watchModePollInterval = .milliseconds(10)
        let session = ComputerUseSession(
            target: target,
            lease: lease,
            configuration: configuration,
            approvals: approvals,
            activity: { await log.record($0) }
        )
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        return (target, session)
    }

    private let click = ComputerAction.click(at: .ref("e2", observation: "o_1"))

    @Test("Vendor safety checks decode from OpenAI's and Gemini's wire forms")
    func decoding() {
        #expect(ComputerUseSafetySignal(openAISafetyCheckCode: "malicious_instructions") == .maliciousInstructions)
        #expect(ComputerUseSafetySignal(openAISafetyCheckCode: "irrelevant_domain") == .irrelevantDomain)
        #expect(ComputerUseSafetySignal(openAISafetyCheckCode: "sensitive_domain") == .sensitiveDomain)
        #expect(ComputerUseSafetySignal(openAISafetyCheckCode: "new_check") == .other("new_check"))
        #expect(ComputerUseSafetySignal(geminiSafetyDecision: "require_confirmation") == .requireConfirmation)
        #expect(ComputerUseSafetySignal(geminiSafetyDecision: "allowed") == nil)
        #expect(ComputerUseSafetySignal.sensitiveDomain.rawValue == "sensitive-domain")
        #expect(ComputerUseSafetySignal(rawValue: "irrelevant-domain") == .irrelevantDomain)
    }

    @Test("A sensitive-domain signal is confirmed, turns watch mode on, and runs while the user watches")
    func watchedRuns() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await make(approvals: approvals)
        await target.setViewers(1)
        let result = await session.perform([click], safetySignals: [0: [.sensitiveDomain]])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await approvals.requests.count == 1, "every vendor signal is a question for the user")
        #expect(await session.isWatchModeOn)
        #expect(await session.events.contains { $0.kind == .watchMode })
        #expect(await target.actCalls.count == 1)
    }

    @Test("In watch mode with nobody watching, the session waits for the live view and goes on once it opens")
    func waitsForViewer() async throws {
        let log = ActivityLog()
        let (target, session) = try await make(log: log)
        await target.setViewers(1)
        _ = await session.perform([click], safetySignals: [0: [.sensitiveDomain]])
        await target.setViewers(0)

        let next = Task { await session.perform([.wait(milliseconds: 1)]) }
        for _ in 0..<500 where await !log.statuses.contains(.waitingForLiveView) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await log.statuses.contains(.waitingForLiveView))
        #expect(await target.actCalls.count == 1, "nothing runs while nobody watches")
        await target.setViewers(1)
        let result = await next.value
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await target.actCalls.count == 2)
        #expect(await log.statuses.last == .acting)
    }

    @Test("If nobody opens the live view in time, the session ends needing the user")
    func nobodyWatches() async throws {
        let (target, session) = try await make(wait: .milliseconds(50))
        let result = await session.perform([click, .wait(milliseconds: 1)], safetySignals: [0: [.sensitiveDomain]])
        #expect(result.outcomes.map(\.effect) == [.notExecuted, .notExecuted])
        #expect(result.terminal == .liveViewRequired)
        #expect(await session.terminalDetail?.contains("live view") == true)
        #expect(await target.actCalls.isEmpty)
        #expect(await target.releases == [.cancelled])
    }

    @Test("On a target with no live view, a present user confirms watch mode once on a card")
    func noLiveView() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await make(manifest: FakeDisplayTarget.hostManifest, approvals: approvals)
        let result = await session.perform([click], safetySignals: [0: [.sensitiveDomain]])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await approvals.requests.first?.title.contains("sensitive page") == true)
        _ = await session.perform([.wait(milliseconds: 1)])
        #expect(await approvals.requests.count == 2, "the watch-mode card is asked once; the signal's own card once")
        #expect(await target.actCalls.count == 2)

        let declining = RecordingComputerUseApprovals(.denied("no"))
        let (other, declined) = try await make(manifest: FakeDisplayTarget.hostManifest, approvals: declining)
        let stopped = await declined.perform([click], safetySignals: [0: [.sensitiveDomain]])
        #expect(stopped.terminal == .liveViewRequired)
        #expect(await other.actCalls.isEmpty)
    }

    @Test("On someone's own screen with a live view, an open view or the user's confirmation both keep the session going")
    func sharedWithLiveView() async throws {
        var manifest = FakeDisplayTarget.hostManifest
        manifest.observerAccess = .stream

        let watching = RecordingComputerUseApprovals(.approved)
        let (watched, session) = try await make(manifest: manifest, approvals: watching)
        await watched.setViewers(1)
        _ = await session.perform([click], safetySignals: [0: [.sensitiveDomain]])
        #expect(await watching.requests.count == 1, "only the signal's own card: the view is open")
        #expect(await watched.actCalls.count == 1)

        let log = ActivityLog()
        let confirming = RecordingComputerUseApprovals(.approved)
        let (atDesk, deskSession) = try await make(manifest: manifest, approvals: confirming, log: log)
        let result = await deskSession.perform([click], safetySignals: [0: [.sensitiveDomain]])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await confirming.requests.count == 2, "the user at the screen confirms rather than open a view of it")
        #expect(await !log.statuses.contains(.waitingForLiveView))
        #expect(await atDesk.actCalls.count == 1)

        let (_, declined) = try await make(manifest: manifest, approvals: RecordingComputerUseApprovals(.denied("no")))
        #expect(await declined.perform([click], safetySignals: [0: [.sensitiveDomain]]).terminal == .liveViewRequired)
    }

    @Test("Any viewer counts as watching, the user's or an observer's")
    func observerWatches() async throws {
        let (target, session) = try await make(wait: .milliseconds(50))
        await target.setViewers(1)
        let result = await session.perform([click], safetySignals: [0: [.sensitiveDomain]])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
    }

    @Test("Without a present user nobody can watch, so the session ends")
    func headless() async throws {
        let (target, session) = try await make(userPresent: false)
        await target.setViewers(1)
        let result = await session.perform([click], safetySignals: [0: [.sensitiveDomain]])
        #expect(result.terminal == .liveViewRequired)
        #expect(await target.actCalls.isEmpty)
    }

    @Test("Other signals ask the user but don't need a live view")
    func otherSignals() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await make(approvals: approvals)
        let result = await session.perform([click], safetySignals: [0: [.maliciousInstructions, .requireConfirmation]])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await approvals.requests.first?.description.contains("vendor safety signal: malicious-instructions") == true)
        #expect(await !session.isWatchModeOn)
        #expect(await target.actCalls.count == 1)
    }

    @Test("A session ended for want of a live view tells the parent it needs the user")
    func resultStatus() throws {
        let task = try ComputerUseTask(
            arguments: .object(["goal": .string("x"), "success_criteria": .string("paid"), "domains": .string("bank.example:full")]),
            defaults: ComputerUseSpecialistDefaults(target: "fake-browser")
        )
        let result = ComputerUseResultBuilder.build(
            task: task,
            verifications: [],
            terminal: .liveViewRequired,
            terminalDetail: "nobody opened the live view",
            budget: ComputerUseResult.Budget(stepsUsed: 3, stepsGranted: 60, extensions: 0),
            child: .completed,
            unresolvedHandoff: nil,
            headlessDenials: [],
            finalText: nil,
            actionsLog: "3 actions"
        )
        #expect(result.status == .needsUser)
        #expect(result.reason == "nobody opened the live view")
    }
}
