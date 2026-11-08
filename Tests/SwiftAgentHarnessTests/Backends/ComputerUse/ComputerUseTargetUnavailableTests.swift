import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use on a target the user must wake or unlock")
struct ComputerUseTargetUnavailableTests {
    static let asleep = "this Mac's display is asleep or disconnected"
    static let locked = "this Mac is locked; unlock it and try again"

    private static func request(_ target: FakeDisplayTarget) -> LeaseRequest {
        LeaseRequest(
            target: target.manifest.id,
            agentID: "agent",
            grants: [.app(bundleID: ComputerUseFixtures.textEdit.bundleID, tier: .full)],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            initiator: .operator,
            userPresent: true
        )
    }

    @Test("An observation the target can't make ends the session at once, with the target's reason")
    func observeEndsSession() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        await target.setErrors(observe: .targetUnavailable(Self.asleep))
        let result = await session.perform([ComputerUseSessionFixtures.observe, ComputerUseSessionFixtures.observe])
        #expect(result.outcomes.map(\.effect) == [.refused, .notExecuted])
        #expect(result.outcomes.first?.evidence == Self.asleep)
        #expect(result.terminal == .targetUnavailable)
        #expect(await session.terminalDetail == Self.asleep)
        #expect(await target.releases == [.cancelled])
    }

    @Test("An action the target can't deliver ends the session too, and nothing after it runs")
    func actEndsSession() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        await target.setErrors(act: .targetUnavailable(Self.locked))
        let result = await session.perform([.click(at: .ref("e2", observation: "o_1")), .wait(milliseconds: 1)])
        #expect(result.outcomes.map(\.effect) == [.refused, .notExecuted])
        #expect(result.terminal == .targetUnavailable)
        #expect(await session.terminalDetail == Self.locked)
    }

    @Test("A session ended on an unavailable target tells the parent it needs the user, with the target's reason")
    func resultStatus() throws {
        let task = try ComputerUseTask(
            arguments: .object(["goal": .string("x"), "success_criteria": .string("typed"), "apps": .string("com.apple.TextEdit:full")]),
            defaults: ComputerUseSpecialistDefaults(target: "fake-host")
        )
        let result = ComputerUseResultBuilder.build(
            task: task,
            verifications: [],
            terminal: .targetUnavailable,
            terminalDetail: Self.asleep,
            budget: ComputerUseResult.Budget(stepsUsed: 1, stepsGranted: 60, extensions: 0),
            child: .completed,
            unresolvedHandoff: nil,
            headlessDenials: [],
            finalText: nil,
            actionsLog: "1 action"
        )
        #expect(result.status == .needsUser)
        #expect(result.reason == Self.asleep)
        #expect(ComputerUseTerminalReason.targetUnavailable.rawValue == "target-unavailable")
    }

    @Test("A lease the target refuses as unavailable is a lease denial carrying the target's reason")
    func leaseDenial() async throws {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        await target.setErrors(lease: .targetUnavailable(Self.locked))
        let registry = try DisplayTargetRegistry(targets: [target])
        await #expect(throws: ComputerUseLeaseDenial.targetUnavailable(Self.locked)) {
            _ = try await registry.lease(Self.request(target), approve: { $0.review.grantable.map(\.grant) })
        }
        let task = try ComputerUseTask(
            arguments: .object(["goal": .string("x"), "success_criteria": .string("typed"), "apps": .string("com.apple.TextEdit:full")]),
            defaults: ComputerUseSpecialistDefaults(target: target.manifest.id)
        )
        let result = SubAgentSpawnService.leaseDenialResult(ComputerUseLeaseDenial.targetUnavailable(Self.locked), task: task)
        #expect(result.status == .needsUser)
        #expect(result.reason == Self.locked)
    }

    @Test("The unavailable reason crosses the display host wire intact")
    func wire() throws {
        let error = DisplayTargetError.targetUnavailable(Self.locked)
        let decoded = try JSONDecoder().decode(DisplayTargetError.self, from: JSONEncoder().encode(error))
        #expect(decoded == error)
    }
}
