import Foundation
import Logging
import SwiftAgentKit
import Synchronization
import Testing
@testable import SwiftAgentHarness

/// Coverage for the three meter branches in `TriggersRuntimeWiring.resolve`.
///
/// `resolve` is the composition entry point for this whole surface and was called from **nowhere** —
/// not production, not tests — so its wiring could break and nothing would say. That matters most
/// now that `meterConversationCostFromRunRollups` defaults to `true`: a flipped default with no
/// coverage is a behaviour change nobody is holding.
@Suite("TriggersRuntimeWiring meter selection")
struct TriggersRuntimeWiringMeterTests {
    private func makeConfiguration() -> TriggersRuntimeWiring.Configuration {
        TriggersRuntimeWiring.Configuration(
            dataDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("wiring-meter-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func resolve(
        _ configuration: TriggersRuntimeWiring.Configuration,
        runtime: any APILayerChatRuntimeManaging
    ) -> TriggersRuntimeBundle {
        TriggersRuntimeWiring.resolve(
            configuration: configuration,
            runtime: runtime,
            scheduleToolPorts: TriggersRuntimeWiring.ScheduleToolPorts(
                catalogPort: ScheduleToolCatalogPort(getConversation: { _ in nil })
            ),
            dedupeCheckAndSet: { _, _ in true },
            createConversation: { _ in UUID() },
            delegatedPorts: TriggersRuntimeWiring.DelegatedPorts(
                spawnSubAgent: { _, _, _ in UUID() },
                sendMessageAndRun: { _, _ in },
                lastAssistantText: { _ in nil },
                stampDelegatedHost: { _, _, _ in },
                resolveParentConversation: { _ in nil }
            ),
            logger: Logger(label: "test")
        )
    }

    /// A conversation whose one run is finished and priced — what the in-package meter reads.
    private func runtimeReporting(conversationID: UUID) -> RecordingRunsRuntime {
        RecordingRunsRuntime(pages: [
            nil: ConversationRunListResponse(
                runs: [
                    ConversationRunInfo(
                        id: UUID(),
                        conversationID: conversationID,
                        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        endedAt: Date(timeIntervalSince1970: 1_700_000_100),
                        outcome: .completed,
                        iterationCount: 1,
                        toolCallCount: 0,
                        firstMessageId: "m1",
                        costRollup: ConversationRunCostRollup(usd: 0.75)
                    )
                ],
                cursor: nil
            )
        ])
    }

    /// Drives one fire through the resolved bundle's own budget gate, so the assertion is about the
    /// port `resolve` installed rather than about a meter built in the test.
    private func settleOneFire(_ bundle: TriggersRuntimeBundle, conversationID: UUID) async throws {
        let gate = try #require(bundle.dispatch.activationPolicy.budget)
        let trigger = HarnessTrigger(
            id: "t1",
            source: .webhook,
            sourceMetadata: ["routeName": "deploy"],
            payload: "go",
            initiator: TriggerInitiator(kind: .external, id: "ci"),
            trust: .knownParty
        )
        gate.indexRun(trigger: trigger, conversationID: conversationID)
        await gate.settlePending(sourceKey: TriggerBudgetGate.sourceKey(for: trigger))
    }

    @Test("the in-package meter is installed by default")
    func inPackageMeterOnByDefault() async throws {
        let configuration = makeConfiguration()
        #expect(configuration.meterConversationCostFromRunRollups)
        let conversationID = UUID()
        let runtime = runtimeReporting(conversationID: conversationID)
        try await settleOneFire(resolve(configuration, runtime: runtime), conversationID: conversationID)
        // The runtime was asked — proof the wiring installed a real meter, not a nil port.
        #expect(runtime.calls.isEmpty == false)
        #expect(runtime.calls.allSatisfy { $0.conversationID == conversationID })
    }

    /// Opting out must leave the port genuinely unmetered, not merely quieter.
    @Test("opting out installs no meter")
    func optingOutInstallsNoMeter() async throws {
        var configuration = makeConfiguration()
        configuration.meterConversationCostFromRunRollups = false
        let conversationID = UUID()
        let runtime = runtimeReporting(conversationID: conversationID)
        try await settleOneFire(resolve(configuration, runtime: runtime), conversationID: conversationID)
        #expect(runtime.calls.isEmpty)
    }

    /// An explicit host meter always wins, whatever the opt-in flag says.
    @Test("an explicit host meter beats the in-package one")
    func explicitMeterWins() async throws {
        var configuration = makeConfiguration()
        configuration.meterConversationCostFromRunRollups = true
        let asked = Mutex<[UUID]>([])
        configuration.conversationCostUSD = { id in
            asked.withLock { $0.append(id) }
            return 1.25
        }
        let conversationID = UUID()
        let runtime = runtimeReporting(conversationID: conversationID)
        try await settleOneFire(resolve(configuration, runtime: runtime), conversationID: conversationID)
        #expect(asked.withLock { $0 } == [conversationID])
        // The in-package meter must not have been built at all.
        #expect(runtime.calls.isEmpty)
    }
}
