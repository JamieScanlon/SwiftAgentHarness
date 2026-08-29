import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

/// Decision units of the in-process delegate model-turn path. The end-to-end spawn/drain flow is
/// covered by the integration cases listed in `docs/PROMPTCONFIG.md`'s localAgents section.
@Suite("Local agent delegate dispatch")
struct LocalAgentDelegateDispatchTests {
    // MARK: - Status derived from runtime signals, not from the child's text

    @Test("Completion maps to done; every non-completion maps to failed")
    func lifecyclePhaseDerivedFromRuntimeOutcome() {
        #expect(SubAgentSpawnService.lifecyclePhase(for: .completed("Done!")) == .done)
        #expect(SubAgentSpawnService.lifecyclePhase(for: .failed("boom")) == .failed)
        #expect(SubAgentSpawnService.lifecyclePhase(for: .timedOut(30)) == .failed)
        #expect(SubAgentSpawnService.lifecyclePhase(for: .cancelled) == .failed)
    }

    @Test("A child that reports success while the run failed is still recorded as failed")
    func doesNotTrustSelfReportedSuccess() {
        // The child's text says "Done!"; the runtime outcome says the run never completed.
        #expect(SubAgentSpawnService.lifecyclePhase(for: .failed("Done!")) == .failed)
        #expect(SubAgentSpawnService.lifecycleError(for: .failed("Done!")) == "Done!")
    }

    @Test("Lifecycle error text is present exactly for non-completions")
    func lifecycleErrorText() {
        #expect(SubAgentSpawnService.lifecycleError(for: .completed("ok")) == nil)
        #expect(SubAgentSpawnService.lifecycleError(for: .timedOut(30)) == "delegate run exceeded runTimeoutSeconds budget of 30s")
        #expect(SubAgentSpawnService.lifecycleError(for: .cancelled) == "delegate run cancelled")
    }

    // MARK: - Tool result content

    @Test("Successful result returns the child's report with trailing whitespace stripped")
    func stripsTrailingWhitespaceFromResult() {
        let content = SubAgentSpawnService.toolResultContent(
            for: .completed("Refactored the parser.\n\n   \n"),
            displayName: "Coding Agent"
        )
        #expect(content == "Refactored the parser.")
    }

    @Test("An all-whitespace report does not produce an empty tool result")
    func neverReturnsEmptyContent() {
        let content = SubAgentSpawnService.toolResultContent(for: .completed("   \n "), displayName: "Coding Agent")
        #expect(content.isEmpty == false)
        #expect(content.contains("Coding Agent"))
    }

    @Test("Failure, timeout and cancellation surface as explanatory text naming the agent")
    func failureContentIsExplanatory() {
        #expect(
            SubAgentSpawnService.toolResultContent(for: .failed("model unavailable"), displayName: "Coding Agent")
                == "Delegate 'Coding Agent' failed: model unavailable"
        )
        let timedOut = SubAgentSpawnService.toolResultContent(for: .timedOut(45), displayName: "Coding Agent")
        #expect(timedOut.contains("45s"))
        // The message must name the setting; "300s timeout" alone reads as the tool-call timeout,
        // which fails for a different reason and has a different fix.
        #expect(timedOut.contains("runTimeoutSeconds"))
        #expect(SubAgentSpawnService.toolResultContent(for: .cancelled, displayName: "Coding Agent").contains("cancelled"))
    }

    @Test("Oversized reports are bounded before reaching the parent transcript")
    func boundsOversizedReports() {
        let oversized = String(repeating: "x", count: SubAgentDelegateResultBounds.defaultMaxBytes + 5_000)
        let content = SubAgentSpawnService.toolResultContent(for: .completed(oversized), displayName: "Coding Agent")
        #expect(content.utf8.count < oversized.utf8.count)
    }

    @Test("Trailing-whitespace trimming leaves interior whitespace intact")
    func trimsOnlyTrailingWhitespace() {
        #expect(SubAgentSpawnService.trimmingTrailingWhitespace("a\n\nb \t\n") == "a\n\nb")
        #expect(SubAgentSpawnService.trimmingTrailingWhitespace("") == "")
    }

    // MARK: - Completion notification shape

    @Test("The notification yields role to the transcript tail")
    func notificationAvoidsConsecutiveSameRole() {
        // Two consecutive user messages are rejected by most providers.
        #expect(SubAgentSpawnService.completionNotificationRole(followingTailRole: .user) == .assistant)
        #expect(SubAgentSpawnService.completionNotificationRole(followingTailRole: .assistant) == .user)
        #expect(SubAgentSpawnService.completionNotificationRole(followingTailRole: .tool) == .user)
        #expect(SubAgentSpawnService.completionNotificationRole(followingTailRole: nil) == .user)
    }

    @Test("The notification carries a runtime-derived status and the delegate's report")
    func notificationBodyShape() {
        let body = SubAgentSpawnService.completionNotificationBody(
            outcome: .completed("Found it in Parser.swift."),
            displayName: "Explore",
            toolCallID: "call-7"
        )
        #expect(body.contains("<status>completed</status>"))
        #expect(body.contains("<tool-call-id>call-7</tool-call-id>"))
        #expect(body.contains("Found it in Parser.swift."))
        // The agent must relay in its own voice rather than echo the envelope.
        #expect(body.contains("do not repeat this block verbatim"))
    }

    @Test("Non-completions are reported as such, not as a silent empty result")
    func notificationStatusForFailures() {
        #expect(SubAgentSpawnService.completionNotificationBody(outcome: .failed("boom"), displayName: "X", toolCallID: "c")
            .contains("<status>failed</status>"))
        #expect(SubAgentSpawnService.completionNotificationBody(outcome: .timedOut(30), displayName: "X", toolCallID: "c")
            .contains("<status>timed out</status>"))
        #expect(SubAgentSpawnService.completionNotificationBody(outcome: .cancelled, displayName: "X", toolCallID: "c")
            .contains("<status>cancelled</status>"))
    }

    // MARK: - Depth folding

    @Test("Per-agent and mode-profile depth caps fold to the tighter of the two")
    func foldsDepthCaps() {
        #expect(SubAgentSpawnService.effectiveMaxDepth(modeProfileMaxDepth: nil, definitionMaxDepth: nil) == nil)
        #expect(SubAgentSpawnService.effectiveMaxDepth(modeProfileMaxDepth: 2, definitionMaxDepth: nil) == 2)
        #expect(SubAgentSpawnService.effectiveMaxDepth(modeProfileMaxDepth: nil, definitionMaxDepth: 1) == 1)
        #expect(SubAgentSpawnService.effectiveMaxDepth(modeProfileMaxDepth: 3, definitionMaxDepth: 1) == 1)
        #expect(SubAgentSpawnService.effectiveMaxDepth(modeProfileMaxDepth: 1, definitionMaxDepth: 3) == 1)
    }

    @Test("Absent caps stay nil so the transport cap and fail-closed fallback still apply")
    func absentCapsDoNotSynthesiseALimit() {
        #expect(SubAgentSpawnService.effectiveMaxDepth(modeProfileMaxDepth: nil, definitionMaxDepth: nil) == nil)
    }

    // MARK: - Argument mapping

    @Test("The optional description argument supplies the task label")
    func readsTaskLabel() {
        #expect(
            SubAgentSpawnService.delegateTaskLabel(from: .object([
                "instructions": .string("Refactor the parser and add tests."),
                "description": .string("Refactor parser"),
            ])) == "Refactor parser"
        )
    }

    @Test("A missing or blank description yields no label, so the agent display name is used")
    func missingTaskLabel() {
        #expect(SubAgentSpawnService.delegateTaskLabel(from: .object(["instructions": .string("Do the thing.")])) == nil)
        #expect(SubAgentSpawnService.delegateTaskLabel(from: .object(["description": .string("   ")])) == nil)
        #expect(SubAgentSpawnService.delegateTaskLabel(from: .string("not an object")) == nil)
    }

    @Test("The instructions argument is read back verbatim as the child's brief")
    func readsInstructions() {
        let brief = "Refactor the parser and add tests."
        #expect(
            SubAgentSpawnService.delegateInstructions(from: .object(["instructions": .string(brief)])) == brief
        )
        #expect(SubAgentSpawnService.delegateInstructions(from: .object([:])) == "")
    }

    // MARK: - Per-call delivery-mode override

    @Test("run_in_background is read as a boolean override")
    func readsRunInBackgroundOverride() {
        #expect(
            SubAgentSpawnService.delegateRunInBackground(from: .object(["run_in_background": .boolean(true)])) == true
        )
        #expect(
            SubAgentSpawnService.delegateRunInBackground(from: .object(["run_in_background": .boolean(false)])) == false
        )
    }

    @Test("Stringified booleans are accepted, anything else leaves the agent default in force")
    func tolerantRunInBackgroundParsing() {
        #expect(SubAgentSpawnService.delegateRunInBackground(from: .object(["run_in_background": .string("true")])) == true)
        #expect(SubAgentSpawnService.delegateRunInBackground(from: .object(["run_in_background": .string("False")])) == false)
        // A nil result means "no override", never a silent false.
        #expect(SubAgentSpawnService.delegateRunInBackground(from: .object([:])) == nil)
        #expect(SubAgentSpawnService.delegateRunInBackground(from: .object(["run_in_background": .double(1)])) == nil)
        #expect(SubAgentSpawnService.delegateRunInBackground(from: .object(["run_in_background": .string("yes")])) == nil)
        #expect(SubAgentSpawnService.delegateRunInBackground(from: .string("not an object")) == nil)
    }

    @Test("The provider's parameter names match what the spawn service reads back")
    func argumentNamesMatchProviderSchema() {
        #expect(SubAgentSpawnService.instructionsArgumentName == "instructions")
        #expect(SubAgentSpawnService.taskLabelArgumentName == "description")
        #expect(
            SubAgentSpawnService.instructionsArgumentName
                == InProcessLocalAgentToolProvider.instructionsParameterName
        )
        #expect(
            SubAgentSpawnService.taskLabelArgumentName
                == InProcessLocalAgentToolProvider.descriptionParameterName
        )
        #expect(
            SubAgentSpawnService.runInBackgroundArgumentName
                == InProcessLocalAgentToolProvider.runInBackgroundParameterName
        )
    }
}
