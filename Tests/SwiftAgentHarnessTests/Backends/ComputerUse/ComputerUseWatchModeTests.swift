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
        humanPresence: .none
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
            operatorInitiated: true,
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
        await target.setUserViewers(1)
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
        await target.setUserViewers(1)
        _ = await session.perform([click], safetySignals: [0: [.sensitiveDomain]])
        await target.setUserViewers(0)

        let next = Task { await session.perform([.wait(milliseconds: 1)]) }
        for _ in 0..<500 where await !log.statuses.contains(.waitingForLiveView) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await log.statuses.contains(.waitingForLiveView))
        #expect(await target.actCalls.count == 1, "nothing runs while nobody watches")
        await target.setUserViewers(1)
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
        #expect(await target.releases == [.aborted])
    }

    @Test("A target with no live view can't be watched, so the session ends without asking")
    func noLiveView() async throws {
        let approvals = RecordingComputerUseApprovals(.approved)
        let (target, session) = try await make(manifest: FakeDisplayTarget.hostManifest, approvals: approvals)
        let result = await session.perform([click], safetySignals: [0: [.sensitiveDomain]])
        #expect(result.terminal == .liveViewRequired)
        #expect(await approvals.requests.isEmpty)
        #expect(await target.actCalls.isEmpty)
    }

    @Test("Without a present user nobody can watch, so the session ends")
    func headless() async throws {
        let (target, session) = try await make(userPresent: false)
        await target.setUserViewers(1)
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
