import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use: missing grants and refusals")
struct ComputerUseRefusalTests {
    private let classifier = ComputerUseActionClassifier()

    private func classify(
        _ action: ComputerAction,
        grants: [ComputerUseGrant],
        observations: [DisplayObservation] = [ComputerUseFixtures.observation(id: "o_1")],
        focusedApp: AppIdentity? = ComputerUseFixtures.textEdit
    ) -> ComputerUseClassification {
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        return classifier.classify(
            action,
            context: ComputerUseClassificationContext(grants: ComputerUseGrantSet(grants), observation: { byID[$0] }, focusedApp: focusedApp)
        )
    }

    private static let openApple = ComputerAction.openURL("https://www.apple.com/")
    private static let safariOnly: [ComputerUseGrant] = [.app(bundleID: "com.apple.Safari", tier: .full)]

    @Test("An out-of-grant refusal names the grant that would have allowed it")
    func classifierNamesMissingGrant() {
        #expect(classify(Self.openApple, grants: Self.safariOnly).missingGrant == .domain("www.apple.com", tier: .click))
        #expect(
            classify(.openURL("https://docs.example.com/a"), grants: [.domain("example.com", tier: .view)]).missingGrant
                == .domain("docs.example.com", tier: .click)
        )
        let page = ComputerUseFixtures.observation(id: "o_w", app: ComputerUseFixtures.safari, url: "https://www.apple.com/")
        #expect(
            classify(.click(at: .ref("e2", observation: "o_w")), grants: Self.safariOnly, observations: [page]).missingGrant
                == .domain("www.apple.com", tier: .click)
        )
        #expect(
            classify(.type(text: "hi"), grants: [.app(bundleID: "com.apple.TextEdit", tier: .click)]).missingGrant
                == .app(bundleID: "com.apple.TextEdit", tier: .full)
        )
        let terminal = ComputerUseFixtures.observation(id: "o_t", app: ComputerUseFixtures.terminal)
        #expect(
            classify(.click(at: .ref("e2", observation: "o_t")), grants: [], observations: [terminal], focusedApp: ComputerUseFixtures.terminal).missingGrant
                == .app(bundleID: "com.apple.Terminal", tier: .click)
        )
    }

    @Test("Refusals no grant can fix name none")
    func classifierNamesNoGrant() {
        #expect(classify(.openURL("file:///etc/passwd"), grants: Self.safariOnly).missingGrant == nil)
        #expect(classify(.launch(app: "com.apple.Safari"), grants: Self.safariOnly).missingGrant == nil)
        #expect(classify(.click(at: .ref("e2", observation: "o_gone")), grants: Self.safariOnly).missingGrant == nil)
    }

    @Test("A missing grant is refused as fixed for the run and recorded once per subject, at the highest tier asked")
    func sessionRecordsMissingGrants() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(grants: [.app(bundleID: "com.apple.TextEdit", tier: .click)])
        let refused = await session.perform([Self.openApple])
        let evidence = try #require(refused.outcomes.first?.evidence)
        #expect(refused.outcomes.first?.effect == .refused)
        #expect(evidence.hasPrefix("domain www.apple.com is not granted"))
        #expect(evidence.contains("grants can't change during this run"))
        #expect(evidence.contains("domains: www.apple.com:click"))

        _ = await session.perform([Self.openApple])
        _ = await session.perform([.type(text: "hi")])
        #expect(await session.missingGrants == [
            .domain("www.apple.com", tier: .click),
            .app(bundleID: "com.apple.TextEdit", tier: .full),
        ])
    }

    @Test("A session whose actions are all refused ends with no-progress once the window fills, with no steps used")
    func refusalsFillTheWindow() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(
            budgets: ComputerUseBudgets(steps: 100, noProgressSteps: 4, maxDuration: .seconds(3600))
        )
        var last = ComputerUseBatchResult(outcomes: [], records: [], observations: [], terminal: nil, escalation: nil)
        for _ in 0..<3 { last = await session.perform([Self.openApple]) }
        #expect(last.escalation == .askUser)
        #expect(await session.terminalReason == nil)

        last = await session.perform([Self.openApple])
        #expect(last.terminal == .noProgress)
        #expect(await session.terminalReason == .noProgress)
        #expect(await session.terminalDetail == "no progress in the last 4 attempts, 4 of them refused")
        #expect(await session.stepCount == 0)
        #expect(await session.perform([ComputerUseSessionFixtures.observe]).outcomes.first?.effect == .notExecuted)
    }

    @Test("Progress clears the refusals counted toward the window")
    func progressClearsRefusals() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(
            budgets: ComputerUseBudgets(steps: 100, noProgressSteps: 4, maxDuration: .seconds(3600)),
            successCriteria: ["The document is open"]
        )
        for _ in 0..<3 { _ = await session.perform([Self.openApple]) }
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        try await session.verify(criterion: "1", met: true, evidence: "open", observation: "o_1")
        for _ in 0..<3 { _ = await session.perform([Self.openApple]) }
        #expect(await session.terminalReason == nil)
    }

    @Test("Refusals while the user has taken over don't count toward the window")
    func takeoverRefusalsDontCount() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make(
            budgets: ComputerUseBudgets(steps: 100, noProgressSteps: 2, maxDuration: .seconds(3600))
        )
        try await session.setTakeover(true)
        for _ in 0..<5 { _ = await session.perform([ComputerUseSessionFixtures.observe]) }
        try await session.setTakeover(false)
        #expect(await session.terminalReason == nil)
    }

    @Test("A handoff cancelled while waiting ends takeover, even on a target that refuses work from a cancelled task")
    func cancelledHandoffEndsTakeover() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(oversight: WaitsUntilCancelledOversight())
        await target.setFailsWhenCancelled(true)
        let handoff = Task { await session.handoff(reason: .login, prompt: "Sign in") }
        while await !session.isTakeoverActive { await Task.yield() }
        handoff.cancel()
        #expect(await handoff.value == .declined)
        #expect(await session.isTakeoverActive == false)
        #expect(await target.takeoverStates == [true, false])
        #expect(await session.perform([ComputerUseSessionFixtures.observe]).outcomes.first?.effect == .confirmed)
    }

    @Test("Ending from a cancelled task still ends takeover and releases the lease")
    func endFromCancelledTask() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        try await session.setTakeover(true)
        await target.setFailsWhenCancelled(true)
        let ending = Task {
            try? await Task.sleep(for: .seconds(60))
            await session.end()
        }
        ending.cancel()
        await ending.value
        #expect(await target.takeoverStates == [true, false])
        #expect(await target.releases == [.completed])
    }

    @Test("Every computer-use tool bounds its own run time, so the per-call timeout never cuts off a wait on the user")
    func toolsBoundOwnRunTime() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make()
        let provider = ComputerUseToolProvider(session: session)
        let tag = ToolRegistryEntry.PolicyTag.boundsOwnRunTime.rawValue
        var entries: [ToolRegistryEntry] = []
        for definition in await provider.availableTools() {
            let tags = await provider.policyTags(for: definition).map(\.rawValue)
            #expect(tags.contains(tag), "\(definition.name)")
            #expect(provider.descriptorHintsByToolName[definition.name]?.policyTags.map(\.rawValue).contains(tag) == true, "\(definition.name)")
            entries.append(ToolRegistryEntry(
                definition: definition,
                source: .local,
                policyTags: Set(tags.compactMap(ToolRegistryEntry.PolicyTag.init(rawValue:)))
            ))
        }
        let contract = AgentRuntimeToolDispatchContract.conservativeDefault
        for name in [ComputerUseToolProvider.handoffToolName, ComputerUseToolProvider.askUserToolName, ComputerUseToolProvider.clickToolName] {
            #expect(ToolDispatchWatchdog.timeoutSeconds(forToolNamed: name, entries: entries, contract: contract) == nil, "\(name)")
        }

        let native = ComputerUseNativeToolProvider(
            session: session,
            toolset: try #require(ComputerUseNativeToolset(version: "computer_toolset_20260801")),
            failures: ComputerUseNativeFailures()
        )
        for name in native.descriptorHintsByToolName.keys {
            #expect(native.descriptorHintsByToolName[name]?.policyTags.map(\.rawValue).contains(tag) == true, "\(name)")
        }
    }
}

/// Answers only by being cancelled, the way the oversight coordinator declines a request whose caller went away.
private struct WaitsUntilCancelledOversight: ComputerUseOversight {
    func askUser(_ question: String) async -> ComputerUseUserReply {
        try? await Task.sleep(for: .seconds(60))
        return .unavailable
    }

    func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult {
        try? await Task.sleep(for: .seconds(60))
        return .declined
    }
}
