import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use budgets: extensions, ceilings, and endings")
struct ComputerUseExtensionTests {
    private typealias S = ComputerUseSessionFixtures

    private static func budgets(
        steps: Int = 3,
        ceiling: Int = 4,
        noProgress: Int = 100,
        maxDuration: Duration = .seconds(3_600),
        deadline: Date? = nil
    ) -> ComputerUseBudgets {
        ComputerUseBudgets(steps: steps, ceilingSteps: ceiling, extensionShare: 0.5, noProgressSteps: noProgress, maxDuration: maxDuration, deadline: deadline)
    }

    private static func make(
        _ budgets: ComputerUseBudgets,
        userPresent: Bool = true,
        oversight: ScriptedComputerUseOversight? = ScriptedComputerUseOversight(reply: "yes"),
        clock: ComputerUseTestClock = ComputerUseTestClock()
    ) async throws -> (FakeDisplayTarget, ComputerUseSession) {
        try await S.make(
            manifest: FakeDisplayTarget.vmManifest,
            userPresent: userPresent,
            budgets: budgets,
            oversight: oversight,
            clock: clock
        )
    }

    /// Click, move to a page not seen before, and observe it: two steps that make progress.
    private static func advance(_ target: FakeDisplayTarget, _ session: ComputerUseSession, to page: Int) async {
        let observation = await session.latestObservation?.id ?? "o_1"
        _ = await session.perform([.click(at: .ref("e2", observation: observation))])
        await target.setObserved(app: ComputerUseFixtures.textEdit, url: "https://example.com/\(page)")
        _ = await session.perform([S.observe])
    }

    @Test("A used-up allotment is extended by its share when the session made progress since the last grant")
    func extendsOnProgress() async throws {
        let (target, session) = try await Self.make(Self.budgets(steps: 3, ceiling: 10))
        _ = await session.perform([S.observe])
        await Self.advance(target, session, to: 1)
        let result = await session.perform([S.observe])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        let budgets = await session.budgets
        #expect(budgets.steps == 5)
        #expect(await session.extensions == 1)
        let event = try #require(await session.events.first { $0.kind == .extended })
        #expect(event.stepsGranted == 5)
        #expect(event.statesReached == 1)
        #expect(event.criteriaVerified == 0)
    }

    @Test("A used-up allotment with no progress since the last grant ends the session as budget-exhausted")
    func endsWithoutProgress() async throws {
        let (target, session) = try await Self.make(Self.budgets(steps: 2, ceiling: 10))
        _ = await session.perform([S.observe, .wait(milliseconds: 1)])
        let result = await session.perform([S.observe])
        #expect(result.outcomes.map(\.effect) == [.notExecuted])
        #expect(await session.terminalReason == .stepBudget)
        #expect(await session.extensions == 0)
        #expect(await target.releases == [.budgetExhausted])
    }

    @Test("Extensions stop at the ceiling, where a present user's yes grants one more")
    func ceilingAsksUser() async throws {
        let oversight = ScriptedComputerUseOversight(reply: "Yes, keep going")
        let (target, session) = try await Self.make(Self.budgets(steps: 3, ceiling: 4), oversight: oversight)
        _ = await session.perform([S.observe])
        await Self.advance(target, session, to: 1)
        _ = await session.perform([.wait(milliseconds: 1)])
        #expect(await session.budgets.steps == 4)
        #expect(await oversight.questions.isEmpty)

        let result = await session.perform([.wait(milliseconds: 1)])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await oversight.questions.count == 1)
        let budgets = await session.budgets
        #expect(budgets.steps == 6)
        #expect(budgets.ceilingSteps == 6)
        #expect(await session.extensions == 2)
        #expect(await session.events.contains { $0.kind == .ceilingQuestion && $0.answer == .continue })
    }

    @Test("At the ceiling, a no or no user present ends the session as budget-exhausted")
    func ceilingStops() async throws {
        for (reply, present) in [("no", true), (nil, true), ("yes", false)] as [(String?, Bool)] {
            let oversight = ScriptedComputerUseOversight(reply: reply)
            let (target, session) = try await Self.make(Self.budgets(steps: 2, ceiling: 2), userPresent: present, oversight: oversight)
            _ = await session.perform([S.observe])
            await Self.advance(target, session, to: 1)
            #expect(await session.terminalReason == .stepBudget, "\(String(describing: reply)) \(present)")
            #expect(await oversight.questions.count == (present ? 1 : 0))
        }
    }

    @Test("Consecutive steps without progress end the session as no-progress, whatever allotment remains")
    func noProgress() async throws {
        let (target, session) = try await Self.make(Self.budgets(steps: 100, ceiling: 100, noProgress: 3))
        _ = await session.perform([S.observe])
        await Self.advance(target, session, to: 1)
        _ = await session.perform([.wait(milliseconds: 1), .wait(milliseconds: 1)])
        #expect(await session.terminalReason == nil)
        let result = await session.perform([.wait(milliseconds: 1)])
        #expect(result.outcomes.map(\.effect) == [.notExecuted])
        #expect(await session.terminalReason == .noProgress)
        #expect(await target.releases == [.aborted])
    }

    @Test("A deadline ends the session as deadline and is never extended, even with a user present")
    func deadline() async throws {
        let clock = ComputerUseTestClock()
        let oversight = ScriptedComputerUseOversight(reply: "yes")
        let (target, session) = try await Self.make(
            Self.budgets(deadline: clock.now().addingTimeInterval(60)),
            oversight: oversight,
            clock: clock
        )
        clock.advance(seconds: 61)
        _ = await session.perform([S.observe])
        #expect(await session.terminalReason == .deadline)
        #expect(await oversight.questions.isEmpty)
        #expect(await target.releases == [.expired])
    }

    @Test("At the time ceiling a present user's yes adds the share of the ceiling, never past the deadline")
    func timeCeiling() async throws {
        let clock = ComputerUseTestClock()
        let start = clock.now()
        let (_, session) = try await Self.make(
            Self.budgets(maxDuration: .seconds(60), deadline: start.addingTimeInterval(75)),
            clock: clock
        )
        clock.advance(seconds: 61)
        #expect(await session.endsAt == start.addingTimeInterval(60))
        let result = await session.perform([S.observe])
        #expect(result.outcomes.map(\.effect) == [.confirmed])
        #expect(await session.endsAt == start.addingTimeInterval(75))
        #expect(await session.events.contains { $0.kind == .timeExtended })
    }

    @Test("Without a user present the time ceiling ends the session as time-budget")
    func timeCeilingUnattended() async throws {
        let clock = ComputerUseTestClock()
        let oversight = ScriptedComputerUseOversight(reply: "yes")
        let (_, session) = try await Self.make(Self.budgets(maxDuration: .seconds(60)), userPresent: false, oversight: oversight, clock: clock)
        clock.advance(seconds: 61)
        _ = await session.perform([S.observe])
        #expect(await session.terminalReason == .timeBudget)
        #expect(await oversight.questions.isEmpty)
    }

    @Test("The end of a session is logged as an event with the progress behind it")
    func endedEvent() async throws {
        let (_, session) = try await Self.make(Self.budgets(steps: 1, ceiling: 1), userPresent: false)
        _ = await session.perform([S.observe, S.observe])
        let ended = try #require(await session.events.last)
        #expect(ended.kind == .ended)
        #expect(ended.reason == .stepBudget)
    }

    @Test("The indicator reports the current allotment and how many times it was extended")
    func activity() async throws {
        let updates = ActivityRecorder()
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id, agentID: "a", grants: S.grants, budgets: Self.budgets(steps: 3, ceiling: 10),
            operatorInitiated: true, userPresent: true
        ))
        let session = ComputerUseSession(
            target: target,
            lease: lease,
            configuration: ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["x"])),
            activity: { await updates.append($0) },
            now: { ComputerUseFixtures.epoch }
        )
        _ = await session.perform([S.observe])
        await Self.advance(target, session, to: 1)
        _ = await session.perform([S.observe])
        let last = try #require(await updates.all.last)
        #expect(last.maxSteps == 5)
        #expect(last.extensions == 1)
    }
}

@Suite("Computer use budgets: one clock for the session and its child run")
struct ComputerUseChildRunDeadlineTests {
    private typealias S = ComputerUseSessionFixtures

    private static func make(
        userPresent: Bool = true,
        oversight: (any ComputerUseOversight)? = ScriptedComputerUseOversight(reply: "yes"),
        clock: ComputerUseTestClock
    ) async throws -> ComputerUseSession {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { clock.now() })
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "a",
            grants: S.grants,
            budgets: ComputerUseBudgets(steps: 100, noProgressSteps: 100, maxDuration: .seconds(60)),
            operatorInitiated: true,
            userPresent: userPresent
        ))
        return ComputerUseSession(
            target: target,
            lease: lease,
            configuration: ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["x"])),
            oversight: oversight,
            now: { clock.now() }
        )
    }

    @Test("While the session runs, the child's deadline is the lease's end time")
    func live() async throws {
        let clock = ComputerUseTestClock()
        let session = try await Self.make(clock: clock)
        #expect(await session.childRunDeadline(grace: 30) == clock.now().addingTimeInterval(60))
    }

    @Test("At the time ceiling a present user's yes moves the child's deadline with the lease")
    func extended() async throws {
        let clock = ComputerUseTestClock()
        let session = try await Self.make(clock: clock)
        clock.advance(seconds: 60)
        let deadline = await session.childRunDeadline(grace: 30)
        #expect(deadline == clock.now().addingTimeInterval(30))
        #expect(await session.terminalReason == nil)
        #expect(await session.endsAt == deadline)
    }

    @Test("Once the session has ended, the child gets the cleanup grace to wrap up")
    func ended() async throws {
        let clock = ComputerUseTestClock()
        let session = try await Self.make(userPresent: false, clock: clock)
        clock.advance(seconds: 60)
        #expect(await session.childRunDeadline(grace: 30) == clock.now().addingTimeInterval(30))
        #expect(await session.terminalReason == .timeBudget)
        clock.advance(seconds: 10)
        #expect(await session.childRunDeadline(grace: 30) == clock.now().addingTimeInterval(20))
    }

    @Test("The child's timer and an action reaching the time ceiling together ask the user once")
    func asksOnce() async throws {
        let clock = ComputerUseTestClock()
        let oversight = SlowYesOversight()
        let session = try await Self.make(oversight: oversight, clock: clock)
        clock.advance(seconds: 60)
        async let deadline = session.childRunDeadline(grace: 30)
        async let batch = session.perform([S.observe])
        _ = await (deadline, batch)
        #expect(await oversight.asked == 1)
        #expect(await session.terminalReason == nil)
    }
}

private actor SlowYesOversight: ComputerUseOversight {
    private(set) var asked = 0

    func askUser(_ question: String) async -> ComputerUseUserReply {
        asked += 1
        try? await Task.sleep(for: .milliseconds(50))
        return .answered("yes")
    }

    func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult { .declined }
}

@Suite("Computer use: waiting on a person pauses the delegate's idle clock")
struct ComputerUseLivenessOversightTests {
    private actor Observing: ComputerUseOversight {
        let liveness: LocalAgentLiveness
        private(set) var pausedDuringAsk: Bool?
        private(set) var pausedDuringHandoff: Bool?

        init(_ liveness: LocalAgentLiveness) { self.liveness = liveness }

        func askUser(_ question: String) async -> ComputerUseUserReply {
            pausedDuringAsk = liveness.isPaused
            return .answered("yes")
        }

        func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult {
            pausedDuringHandoff = liveness.isPaused
            return .handedBack(note: nil)
        }
    }

    @Test("Questions, handoffs, and ceiling questions pause the clock and resume it after")
    func pauses() async {
        let liveness = LocalAgentLiveness()
        let base = Observing(liveness)
        let oversight = ComputerUseLivenessOversight(base: base, liveness: liveness)
        _ = await oversight.askUser("which file?")
        _ = await oversight.handoff(ComputerUseHandoffRequest(reason: .login, prompt: "log in", target: "t"))
        _ = await oversight.continuePastCeiling(ComputerUseCeilingQuestion(limit: .steps, stepsUsed: 1, extensions: 0, prompt: "more?"))
        #expect(await base.pausedDuringAsk == true)
        #expect(await base.pausedDuringHandoff == true)
        #expect(!liveness.isPaused)
    }
}

private actor ActivityRecorder {
    private(set) var all: [ComputerUseActivity] = []
    func append(_ activity: ComputerUseActivity) { all.append(activity) }
}

@Suite("Computer use result: statuses and the budget block")
struct ComputerUseResultBudgetTests {
    private let task = ComputerUseTask(
        goal: "g",
        successCriteria: ["c"],
        target: "t",
        grants: [],
        budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60))
    )
    private let budget = ComputerUseResult.Budget(stepsUsed: 12, stepsGranted: 15, extensions: 1, lastProgressStep: 9)

    private func build(_ terminal: ComputerUseTerminalReason?, detail: String? = nil) -> ComputerUseResult {
        ComputerUseResultBuilder.build(
            task: task,
            verifications: [],
            terminal: terminal,
            terminalDetail: detail,
            budget: budget,
            child: .completed,
            unresolvedHandoff: nil,
            headlessDenials: [],
            finalText: nil,
            actionsLog: "log"
        )
    }

    @Test("Each way a session runs out maps to a status the parent can act on")
    func statuses() {
        #expect(build(.noProgress).status == .noProgress)
        #expect(build(.deadline).status == .deadline)
        #expect(build(.stepBudget).status == .budgetExhausted)
        #expect(build(.timeBudget).status == .budgetExhausted)
        #expect(build(.costBudget).status == .budgetExhausted)
        #expect(build(.stepBudget, detail: "step ceiling reached").reason == "step ceiling reached")
    }

    @Test("Every result carries the budget block")
    func budgetBlock() throws {
        let result = build(nil)
        #expect(result.budget == budget)
        let json = result.jsonString
        #expect(json.contains("\"stepsGranted\":15"))
        #expect(json.contains("\"status\":\"done-unverified\""))
        #expect(build(.noProgress).jsonString.contains("\"status\":\"no-progress\""))
    }
}
