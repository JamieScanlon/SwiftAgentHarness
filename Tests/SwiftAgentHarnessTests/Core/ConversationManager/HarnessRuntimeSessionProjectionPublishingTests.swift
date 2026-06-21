import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private func makeModel(name: String = "test:latest") -> Model {
    Model(
        protocol: .ollama,
        modelName: name,
        serverURL: URL(string: "http://localhost:11434")!,
        capabilities: [],
        modelProtocol: .ollama
    )
}

private func makeHarnessHost(label: String) throws -> HarnessRuntimeHostFixture {
    try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: label)
}

@Suite("HarnessRuntimeSession — projection publishing & staleness", .serialized)
struct HarnessRuntimeSessionProjectionPublishingTests {

    @Test("Stale projection snapshot is dropped when store frontier lags publish state")
    func staleProjectionDroppedWhenPublishFrontierAheadOfStore() async throws {
        let fixture = try makeHarnessHost(label: "projection-stale")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let (idA, _) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(host: fixture.host, model: model)
        let runtimeSession = fixture.host
        try await runtimeSession.selectConversation(conversationID: idA)

        let baseline = await runtimeSession.currentMessages
        #expect(baseline.contains { $0.content == "UserA-only" })

        await runtimeSession.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .assistant, content: "first-append", timestamp: Date(), toolCalls: []),
        ])
        let afterAppend = await runtimeSession.currentMessages
        #expect(afterAppend.contains { $0.content == "first-append" })

        await runtimeSession.testing_seedProjectionPublishState(
            conversationID: idA,
            frontierEventID: 99_999,
            contentHash: 0
        )
        let metricsBefore = await runtimeSession.contextProjectionService.projectionHardeningMetrics()
        await runtimeSession.testing_refreshProjectedConversationMessages(conversationID: idA)
        let metricsAfter = await runtimeSession.contextProjectionService.projectionHardeningMetrics()

        #expect(metricsAfter.staleProjectionDropCount == metricsBefore.staleProjectionDropCount + 1)

        await runtimeSession.testing_clearProjectionPublishState(conversationID: idA)
        await runtimeSession.testing_refreshProjectedConversationMessages(conversationID: idA)
        let recovered = await runtimeSession.currentMessages
        #expect(recovered.contains { $0.content == "first-append" })
    }

    @Test("Projection refresh for non-selected thread does not replace currentMessages")
    func refreshForBackgroundThreadDoesNotClobberPublishedSelection() async throws {
        let fixture = try makeHarnessHost(label: "projection-background")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let (idA, idB) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(host: fixture.host, model: model)
        let runtimeSession = fixture.host
        try await runtimeSession.selectConversation(conversationID: idA)

        let conversationB = try #require(await runtimeSession.modelConversation(id: idB))
        await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversationB)
        await runtimeSession.testing_setActiveStreamingRun(conversationID: idB, runID: UUID())
        defer { Task { await runtimeSession.testing_setActiveStreamingRun(conversationID: nil, runID: nil) } }
        await runtimeSession.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .assistant, content: "only-on-B", timestamp: Date(), toolCalls: []),
        ])

        let visible = await runtimeSession.currentMessages
        #expect(visible.contains { $0.content == "UserA-only" })
        #expect(visible.contains { $0.content == "only-on-B" } == false)

        await runtimeSession.testing_refreshProjectedConversationMessages(conversationID: idB)
        let visibleAfterBackgroundRefresh = await runtimeSession.currentMessages
        #expect(visibleAfterBackgroundRefresh.contains { $0.content == "UserA-only" })
        #expect(visibleAfterBackgroundRefresh.contains { $0.content == "only-on-B" } == false)
    }

    @Test("Many sequential orchestrator appends preserve order in currentMessages")
    func sequentialOrchestratorAppendsPreserveOrder() async throws {
        let fixture = try makeHarnessHost(label: "projection-order")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let (idA, _) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(host: fixture.host, model: model)
        let runtimeSession = fixture.host
        try await runtimeSession.selectConversation(conversationID: idA)

        var orderedIDs: [UUID] = []
        for index in 0..<6 {
            let id = UUID()
            orderedIDs.append(id)
            await runtimeSession.testing_applyOrchestratorMessages([
                Message(id: id, role: .assistant, content: "chunk-\(index)", timestamp: Date().addingTimeInterval(Double(index)), toolCalls: []),
            ])
        }

        let projected = await runtimeSession.currentMessages
        let indices: [Int] = try orderedIDs.map { id in
            guard let i = projected.firstIndex(where: { $0.id == id }) else {
                throw TestError.missingProjectedMessage(id)
            }
            return i
        }
        for idx in 1..<indices.count {
            #expect(indices[idx] > indices[idx - 1])
        }
    }

    @Test("In-place summary event repair republishes currentMessages at unchanged log tail")
    func inPlaceSummaryRepairRepublishesWithoutNewEventIDs() async throws {
        let fixture = try makeHarnessHost(label: "projection-summary-repair")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel()
        let runtimeSession = fixture.host
        let (idA, _) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(
            host: runtimeSession,
            model: model
        )
        try await runtimeSession.selectConversation(conversationID: idA)

        await runtimeSession.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .assistant, content: "body", timestamp: Date(), toolCalls: []),
        ])
        let assistantID = try #require(
            fixture.stack.conversationManager.rawMessages(conversationID: idA)?
                .first { $0.role == .assistant && $0.content == "body" }?.id
        )

        let badPayload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "should not apply",
            coveredMessageIDs: [assistantID],
            firstCoveredMessageID: assistantID,
            basedOnEventID: 999_999,
            startEventID: 1,
            endEventID: 1,
            succeeded: true,
            createdAt: Date()
        )
        let summaryEventID = try HarnessConversationTestFixtures.appendDerivedTurnSummaryEvent(
            stack: fixture.stack,
            conversationID: idA,
            payload: badPayload,
            basedOnEventID: nil,
            coversStartEventID: 1,
            coversEndEventID: 1
        )

        await runtimeSession.testing_refreshProjectedConversationMessages(conversationID: idA)
        let rejected = await runtimeSession.currentMessages
        #expect(rejected.contains { $0.id == assistantID && $0.content == "body" })
        #expect(rejected.contains { $0.content == "should not apply" } == false)

        let summaryMessageID = UUID()
        let goodPayload = SummaryCreatedEventPayload(
            summaryMessageID: summaryMessageID,
            summaryContent: "rolled",
            coveredMessageIDs: [assistantID],
            firstCoveredMessageID: assistantID,
            basedOnEventID: summaryEventID,
            startEventID: 1,
            endEventID: 1,
            succeeded: true,
            createdAt: Date()
        )
        try HarnessConversationTestFixtures.patchDerivedJournalInnerPayload(
            local: fixture.local,
            conversationID: idA,
            globalEventID: summaryEventID,
            innerPayloadJSON: ConversationEventCodec.encode(goodPayload)
        )

        await runtimeSession.testing_clearProjectionPublishState(conversationID: idA)
        await runtimeSession.testing_refreshProjectedConversationMessages(conversationID: idA)
        let folded = await runtimeSession.currentMessages
        #expect(folded.contains { $0.id == summaryMessageID && $0.content == "rolled" })
        #expect(folded.contains { $0.id == assistantID } == false)
    }
}

private enum TestError: Error {
    case missingProjectedMessage(UUID)
}
