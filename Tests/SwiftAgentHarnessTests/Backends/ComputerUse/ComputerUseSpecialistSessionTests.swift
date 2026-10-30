import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use specialist: per-step reminders and session tracking")
struct ComputerUseSpecialistSessionTests {
    private func provider(
        userPresent: Bool = true,
        oversight: (any ComputerUseOversight)? = nil
    ) async throws -> (FakeDisplayTarget, ComputerUseSession, ComputerUseToolProvider) {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "specialist",
            grants: ComputerUseSessionFixtures.grants,
            budgets: ComputerUseBudgets(steps: 50, maxDuration: .seconds(600)),
            operatorInitiated: true,
            userPresent: userPresent
        ))
        let session = ComputerUseSession(
            target: target,
            lease: lease,
            configuration: ComputerUseSessionConfiguration(task: ComputerUseTaskContext(
                userRequest: ["Export the report."],
                constraints: ["Do not overwrite existing files"],
                successCriteria: ["report.pdf exists", "the dialog is closed"]
            )),
            oversight: oversight,
            now: { ComputerUseFixtures.epoch }
        )
        return (target, session, ComputerUseToolProvider(session: session))
    }

    private func call(_ provider: ComputerUseToolProvider, _ name: String, _ arguments: [String: JSON] = [:]) async throws -> ToolResult {
        try await provider.executeTool(ToolCall(name: name, arguments: .object(arguments), id: "c"))
    }

    @Test("Every screen-tool result restates the constraints and the criteria still unverified")
    func reminderOnEveryStep() async throws {
        let (_, _, provider) = try await provider()
        let observed = try await call(provider, "computer_observe")
        #expect(observed.content.contains("Do not overwrite existing files"))
        #expect(observed.content.contains("1. report.pdf exists"))
        #expect(observed.content.contains("2. the dialog is closed"))
        let clicked = try await call(provider, "computer_click", ["observation": .string("o_1"), "ref": .string("e2")])
        #expect(clicked.content.contains("Do not overwrite existing files"))
    }

    @Test("A verified criterion drops out of the reminder")
    func verifiedCriterionDropsOut() async throws {
        let (_, _, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        _ = try await call(provider, "computer_verify", [
            "criterion": .string("report.pdf exists"), "met": .boolean(true),
            "evidence": .string("listed in Finder"), "observation": .string("o_1"),
        ])
        let next = try await call(provider, "computer_observe")
        #expect(!next.content.contains("1. report.pdf exists"))
        #expect(next.content.contains("2. the dialog is closed"))
    }

    @Test("The verify tool lists the task's criteria so the model can cite them exactly")
    func verifyDescriptionListsCriteria() async throws {
        let (_, _, provider) = try await provider()
        let verify = try #require(await provider.availableTools().first { $0.name == ComputerUseToolProvider.verifyToolName })
        let criterion = try #require(verify.parameters.first { $0.name == "criterion" })
        #expect(criterion.description.contains("report.pdf exists"))
    }

    @Test("Without task criteria or constraints no reminder is added")
    func noReminderWithoutTask() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        let result = try await ComputerUseToolProvider(session: session).executeTool(ToolCall(name: "computer_observe", id: "c"))
        #expect(!result.content.contains(ComputerUseToolProvider.reminderHeading))
    }

    @Test("A handoff nobody could take stays recorded until a later one is handed back")
    func unresolvedHandoffTracked() async throws {
        let (_, unattended, _) = try await provider(userPresent: false)
        _ = await unattended.handoff(reason: .login, prompt: "Sign in to the portal")
        #expect(await unattended.unresolvedHandoff?.reason == .login)

        let (_, present, _) = try await provider(oversight: ScriptedComputerUseOversight())
        _ = await present.handoff(reason: .captcha, prompt: "Solve it")
        #expect(await present.unresolvedHandoff == nil)
    }

    @Test("The action-log summary counts actions by effect")
    func auditSummary() async throws {
        let (_, session, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        _ = try await call(provider, "computer_open_url", ["url": .string("file:///etc/hosts")])
        let summary = await session.auditSummary
        #expect(summary.contains("2 actions"))
        #expect(summary.contains("1 confirmed"))
        #expect(summary.contains("1 refused"))
    }
}
