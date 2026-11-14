import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use specialist: task and result contract")
struct ComputerUseSpecialistContractTests {
    private let defaults = ComputerUseSpecialistDefaults(
        target: "fake-host",
        budgets: ComputerUseBudgetPolicy(defaultSteps: 60, ceilingSteps: 200, maxDuration: .seconds(1_800), maxUSD: 5)
    )

    private func task(_ arguments: [String: JSON]) throws -> ComputerUseTask {
        try ComputerUseTask(arguments: .object(arguments), defaults: defaults)
    }

    @Test("The flat delegate arguments parse into a task: lists, grants with tiers and flags, and budgets")
    func parsesArguments() throws {
        let parsed = try task([
            "goal": .string("Export the open report as PDF."),
            "success_criteria": .string("- report.pdf exists on the Desktop\n2. The export dialog is closed"),
            "constraints": .string("Do not overwrite existing files\n* Stay in TextEdit"),
            "apps": .string("com.apple.TextEdit:full:clipboard-write, com.apple.finder:view"),
            "domains": .string("docs.example.com:click"),
            "steps": .integer(40),
        ])
        #expect(parsed.goal == "Export the open report as PDF.")
        #expect(parsed.successCriteria == ["report.pdf exists on the Desktop", "The export dialog is closed"])
        #expect(parsed.constraints == ["Do not overwrite existing files", "Stay in TextEdit"])
        #expect(parsed.grants == [
            .app(bundleID: "com.apple.TextEdit", tier: .full, flags: [.clipboardWrite]),
            .app(bundleID: "com.apple.finder", tier: .view),
            .domain("docs.example.com", tier: .click),
        ])
        #expect(parsed.target == "fake-host")
        #expect(parsed.budgets == ComputerUseBudgets(steps: 40, ceilingSteps: 200, maxDuration: .seconds(1_800), maxUSD: 5))
    }

    @Test("Requested steps are clamped to the host's ceiling")
    func budgetsClamped() throws {
        let parsed = try task([
            "goal": .string("x"), "success_criteria": .string("y"), "apps": .string("com.apple.TextEdit:full"),
            "steps": .integer(10_000),
        ])
        #expect(parsed.budgets.steps == 200)
        #expect(parsed.budgets.maxDuration == .seconds(1_800))
    }

    @Test("Malformed tasks are rejected with a reason the parent can act on")
    func rejectsMalformed() {
        #expect(throws: ComputerUseTaskError.missing("goal")) {
            try task(["success_criteria": .string("y"), "apps": .string("a.b:full")])
        }
        #expect(throws: ComputerUseTaskError.missing("success_criteria")) {
            try task(["goal": .string("x"), "apps": .string("a.b:full")])
        }
        #expect(throws: ComputerUseTaskError.missing("apps or domains")) {
            try task(["goal": .string("x"), "success_criteria": .string("y")])
        }
        #expect(throws: ComputerUseTaskError.invalid("apps: 'com.x:admin' needs a tier of view, click, or full")) {
            try task(["goal": .string("x"), "success_criteria": .string("y"), "apps": .string("com.x:admin")])
        }
        #expect(throws: ComputerUseTaskError.invalid("return_schema is not valid JSON")) {
            try task(["goal": .string("x"), "success_criteria": .string("y"), "apps": .string("a.b:full"), "return_schema": .string("{")])
        }
    }

    @Test("The child's brief carries the goal, numbered criteria, constraints, and the return schema")
    func brief() throws {
        let parsed = try task([
            "goal": .string("Export the report."),
            "success_criteria": .string("pdf exists\ndialog closed"),
            "constraints": .string("No overwrites"),
            "apps": .string("com.apple.TextEdit:full"),
            "return_schema": .string("{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}"),
        ])
        let brief = parsed.brief
        #expect(brief.contains("Export the report."))
        #expect(brief.contains("1. pdf exists"))
        #expect(brief.contains("2. dialog closed"))
        #expect(brief.contains("No overwrites"))
        #expect(brief.contains("computer_verify"))
        #expect(brief.contains("\"path\""))
    }

    private func verification(_ criterion: String, met: Bool) -> ComputerUseVerification {
        ComputerUseVerification(criterion: criterion, met: met, evidence: "seen", observation: "o_9")
    }

    private func build(
        verifications: [ComputerUseVerification] = [],
        terminal: ComputerUseTerminalReason? = .ended,
        child: ComputerUseChildOutcome = .completed,
        unresolvedHandoff: ComputerUseHandoffRequest? = nil,
        headlessDenials: [String] = [],
        missingGrants: [ComputerUseGrant] = [],
        finalText: String? = "Exported to ~/Desktop/report.pdf",
        returnSchema: JSON? = nil
    ) throws -> ComputerUseResult {
        var parsed = try task([
            "goal": .string("x"), "success_criteria": .string("pdf exists\ndialog closed"), "apps": .string("a.b:full"),
        ])
        parsed.returnSchema = returnSchema
        return ComputerUseResultBuilder.build(
            task: parsed,
            verifications: verifications,
            terminal: terminal,
            budget: ComputerUseResult.Budget(stepsUsed: 12, stepsGranted: 60, extensions: 0),
            child: child,
            unresolvedHandoff: unresolvedHandoff,
            headlessDenials: headlessDenials,
            missingGrants: missingGrants,
            finalText: finalText,
            actionsLog: "12 actions"
        )
    }

    @Test("Done only when every criterion has a verification that is met")
    func doneRequiresAllVerified() throws {
        let done = try build(verifications: [verification("PDF exists", met: true), verification("2", met: true)])
        #expect(done.status == .done)
        #expect(done.verification.map(\.met) == [true, true])
        #expect(done.verification.map(\.criterion) == ["pdf exists", "dialog closed"])

        let partial = try build(verifications: [verification("pdf exists", met: true)])
        #expect(partial.status == .doneUnverified)
        #expect(partial.verification[1].evidence == "not verified")

        let failedCriterion = try build(verifications: [verification("pdf exists", met: true), verification("dialog closed", met: false)])
        #expect(failedCriterion.status == .doneUnverified)
    }

    @Test("Budgets, the kill switch, child failures, and pending human steps map to their statuses")
    func statusMapping() throws {
        #expect(try build(terminal: .stepBudget).status == .budgetExhausted)
        #expect(try build(terminal: .costBudget).status == .budgetExhausted)
        #expect(try build(terminal: .killSwitch).status == .blocked)
        #expect(try build(terminal: .permissionRevoked).status == .blocked)
        #expect(try build(child: .timedOut).status == .budgetExhausted)
        #expect(try build(child: .failed("model error")).status == .failed)
        let handoff = try build(unresolvedHandoff: ComputerUseHandoffRequest(reason: .login, prompt: "Sign in", target: "fake-host"))
        #expect(handoff.status == .needsUser)
        #expect(handoff.handoff == ComputerUseResult.Handoff(reason: "login", prompt: "Sign in"))
        let denied = try build(headlessDenials: ["press Delete account"])
        #expect(denied.status == .needsUser)
        #expect(denied.handoff?.reason == "consequential")
    }

    @Test("Unknown arguments are refused, naming the replacement for known renames")
    func rejectsUnknownArguments() {
        let base: [String: JSON] = ["goal": .string("x"), "success_criteria": .string("y"), "apps": .string("a.b:full")]
        #expect(throws: ComputerUseTaskError.invalid(
            "max_minutes and max_steps are not parameters: use steps for the size of the work; time limits are set by the host"
        )) {
            try task(base.merging(["max_steps": .integer(20), "max_minutes": .integer(5)]) { $1 })
        }
        #expect(throws: ComputerUseTaskError.invalid(
            "colour is not a parameter: the parameters are goal, success_criteria, constraints, apps, domains, target, steps, deadline, return_schema, description"
        )) {
            try task(base.merging(["colour": .string("red")]) { $1 })
        }
        #expect((try? task(base.merging(["description": .string("Open the page")]) { $1 })) != nil)
    }

    @Test("A task refused for a missing grant comes back blocked and names the grants to delegate with")
    func missingGrantsBlock() throws {
        let missing: [ComputerUseGrant] = [.domain("www.apple.com", tier: .click), .app(bundleID: "com.apple.Terminal", tier: .full, flags: [.systemKeys])]
        let blocked = try build(missingGrants: missing)
        #expect(blocked.status == .blocked)
        #expect(blocked.reason == "missing grants: delegate again with domains: www.apple.com:click and apps: com.apple.Terminal:full:system-keys")
        #expect(blocked.missingGrants == [
            ComputerUseResult.MissingGrant(domain: "www.apple.com", tier: .click),
            ComputerUseResult.MissingGrant(app: "com.apple.Terminal", tier: .full, flags: [.systemKeys]),
        ])
        #expect(try build(terminal: .noProgress, missingGrants: missing).status == .blocked)

        let partial = try build(verifications: [verification("pdf exists", met: true)], missingGrants: missing)
        #expect(partial.status == .doneUnverified)
        #expect(partial.missingGrants?.count == 2)

        let object = try #require(try JSONSerialization.jsonObject(with: Data(blocked.jsonString.utf8)) as? [String: Any])
        let entries = try #require(object["missingGrants"] as? [[String: Any]])
        #expect(entries.first?["domain"] as? String == "www.apple.com")
        #expect(entries.first?["tier"] as? String == "click")
        #expect(entries.last?["flags"] as? [String] == ["system-keys"])
        let clean = try #require(try JSONSerialization.jsonObject(with: Data(try build().jsonString.utf8)) as? [String: Any])
        #expect(clean["missingGrants"] == nil)
    }

    @Test("With a return schema the final report is parsed as JSON; otherwise it is text")
    func resultShape() throws {
        let schema: JSON = .object(["type": .string("object")])
        let parsed = try build(finalText: "```json\n{\"path\": \"/tmp/r.pdf\"}\n```", returnSchema: schema)
        #expect(parsed.result.flatMap(ComputerUseTask.compactJSON) == "{\"path\":\"/tmp/r.pdf\"}")
        let text = try build(finalText: "Exported.")
        #expect(text.result.flatMap(ComputerUseTask.compactJSON) == "\"Exported.\"")
        #expect(try build(finalText: "  ").result == nil)
    }

    @Test("The parent receives the result as JSON with the spec's field names")
    func jsonShape() throws {
        let result = try build(verifications: [verification("pdf exists", met: true), verification("dialog closed", met: true)])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.jsonString.utf8)) as? [String: Any])
        #expect(object["status"] as? String == "done")
        #expect(object["actionsLog"] as? String == "12 actions")
        #expect((object["verification"] as? [[String: Any]])?.count == 2)
        #expect(object["result"] as? String == "Exported to ~/Desktop/report.pdf")
    }
}
