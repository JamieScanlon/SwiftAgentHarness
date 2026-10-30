import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use budgets: host policy combined with the task")
struct ComputerUseBudgetPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A task naming no steps gets the host default; the ceiling defaults to three times it")
    func defaults() {
        let policy = ComputerUseBudgetPolicy(defaultSteps: 40, maxDuration: .seconds(1_800))
        let budgets = policy.resolve(steps: nil, deadline: nil)
        #expect(budgets.steps == 40)
        #expect(budgets.ceilingSteps == 120)
        #expect(budgets.extensionShare == 0.5)
        #expect(budgets.noProgressSteps == 8)
        #expect(budgets.maxDuration == .seconds(1_800))
        #expect(budgets.deadline == nil)
    }

    @Test("A task's steps are the first allotment, clamped to the ceiling")
    func stepsClamped() {
        let policy = ComputerUseBudgetPolicy(defaultSteps: 40, ceilingSteps: 100)
        #expect(policy.resolve(steps: 15, deadline: nil).steps == 15)
        #expect(policy.resolve(steps: 10_000, deadline: nil).steps == 100)
        #expect(policy.resolve(steps: 0, deadline: nil).steps == 1)
    }

    @Test("A ceiling below the default is raised to it, and the extension share stays in (0, 1]")
    func policyNormalized() {
        let policy = ComputerUseBudgetPolicy(defaultSteps: 40, ceilingSteps: 10, extensionShare: 4, noProgressSteps: 0)
        #expect(policy.ceilingSteps == 40)
        #expect(policy.extensionShare == 1)
        #expect(policy.noProgressSteps == 1)
        #expect(ComputerUseBudgetPolicy(extensionShare: -1).extensionShare > 0)
    }

    @Test("Cost comes from the host, and the task may only tighten it")
    func costTightenedOnly() {
        let policy = ComputerUseBudgetPolicy(maxUSD: 5)
        #expect(policy.resolve(steps: nil, deadline: nil).maxUSD == 5)
        #expect(policy.resolve(steps: nil, deadline: nil, maxUSD: 2).maxUSD == 2)
        #expect(policy.resolve(steps: nil, deadline: nil, maxUSD: 50).maxUSD == 5)
    }

    @Test("A session ends at the earliest of the time ceiling, the deadline, and the unattended grant expiry")
    func endsAtEarliest() {
        var budgets = ComputerUseBudgets(steps: 10, maxDuration: .seconds(1_800))
        #expect(budgets.endsAt(start: start) == start.addingTimeInterval(1_800))
        budgets.grantExpiry = .seconds(1_200)
        #expect(budgets.endsAt(start: start) == start.addingTimeInterval(1_200))
        budgets.deadline = start.addingTimeInterval(300)
        #expect(budgets.endsAt(start: start) == start.addingTimeInterval(300))
    }

    @Test("A lease's end time is fixed when it is issued, so time spent in the grant dialog isn't charged")
    func leaseEndsAt() {
        let budgets = ComputerUseBudgets(steps: 10, maxDuration: .seconds(600))
        let request = LeaseRequest(target: "t", agentID: "a", grants: [], budgets: budgets, operatorInitiated: true, userPresent: true)
        let lease = Lease(request: request, issuedAt: start)
        #expect(lease.endsAt == start.addingTimeInterval(600))
    }

    @Test("An unattended lease gets the registry's absolute grant expiry; a present user's doesn't")
    func unattendedExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let vm = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { now })
        let registry = DisplayTargetRegistry(targets: [vm], unattendedMaxDuration: .seconds(20 * 60), now: { now })
        func request(userPresent: Bool) -> LeaseRequest {
            LeaseRequest(
                target: vm.manifest.id,
                agentID: "agent",
                grants: [.app(bundleID: "com.apple.TextEdit", tier: .full)],
                budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(3_600)),
                operatorInitiated: true,
                userPresent: userPresent
            )
        }
        let unattended = try await registry.lease(request(userPresent: false), approve: { $0.review.grantable.map(\.grant) })
        #expect(unattended.lease.budgets.grantExpiry == .seconds(20 * 60))
        #expect(unattended.lease.endsAt == now.addingTimeInterval(20 * 60))
        await vm.release(unattended.lease, reason: .completed)

        let attended = try await registry.lease(request(userPresent: true), approve: { $0.review.grantable.map(\.grant) })
        #expect(attended.lease.budgets.grantExpiry == nil)
        #expect(attended.lease.endsAt == now.addingTimeInterval(3_600))
    }
}

@Suite("Computer use budgets: the delegate's steps and deadline")
struct ComputerUseTaskBudgetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let defaults = ComputerUseSpecialistDefaults(
        target: "fake-host",
        budgets: ComputerUseBudgetPolicy(defaultSteps: 60, ceilingSteps: 200, maxDuration: .seconds(1_800), maxUSD: 5)
    )

    private func task(_ extra: [String: JSON]) throws -> ComputerUseTask {
        var arguments: [String: JSON] = [
            "goal": .string("x"), "success_criteria": .string("y"), "apps": .string("com.apple.TextEdit:full"),
        ]
        arguments.merge(extra) { $1 }
        return try ComputerUseTask(arguments: .object(arguments), defaults: defaults, now: now)
    }

    @Test("The parent sizes the work in steps; the host's policy fills in the rest")
    func steps() throws {
        let budgets = try task(["steps": .integer(15)]).budgets
        #expect(budgets.steps == 15)
        #expect(budgets.ceilingSteps == 200)
        #expect(budgets.maxDuration == .seconds(1_800))
        #expect(budgets.maxUSD == 5)
        #expect(try task([:]).budgets.steps == 60)
        #expect(try task(["steps": .integer(10_000)]).budgets.steps == 200)
    }

    @Test("There is no time budget for the parent to set: a minutes argument changes nothing")
    func noMinutes() throws {
        #expect(try task(["max_minutes": .integer(1)]).budgets.maxDuration == .seconds(1_800))
    }

    @Test("A stated deadline is carried as a cutoff")
    func deadline() throws {
        let budgets = try task(["deadline": .string("2027-01-15T08:30:00Z")]).budgets
        #expect(budgets.deadline == ISO8601DateFormatter().date(from: "2027-01-15T08:30:00Z"))
        let offset = try task(["deadline": .string("2027-01-15T08:30:00-07:00")]).budgets
        #expect(offset.deadline == ISO8601DateFormatter().date(from: "2027-01-15T15:30:00Z"))
    }

    @Test("A malformed or past deadline, or fewer than one step, is rejected with a reason")
    func rejected() {
        #expect(throws: ComputerUseTaskError.self) { try task(["deadline": .string("in five minutes")]) }
        #expect(throws: ComputerUseTaskError.self) { try task(["deadline": .string("2020-01-01T00:00:00Z")]) }
        #expect(throws: ComputerUseTaskError.self) { try task(["steps": .integer(0)]) }
    }

    @Test("The delegate tool offers steps and deadline and no time budget")
    func toolParameters() async throws {
        let provider = ComputerUseDelegateToolProvider(targets: [], defaults: defaults)
        let definition = try #require(await provider.availableTools().first { $0.name == ComputerUseDelegateToolProvider.toolName })
        let names = Set(definition.parameters.map(\.name))
        #expect(names.isSuperset(of: ["steps", "deadline"]))
        #expect(names.isDisjoint(with: ["max_steps", "max_minutes"]))
    }
}
