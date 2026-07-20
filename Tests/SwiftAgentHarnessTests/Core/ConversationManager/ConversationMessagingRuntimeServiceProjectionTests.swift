import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationMessagingRuntimeService projection", .serialized)
struct ConversationMessagingRuntimeServiceProjectionTests {
    private func makeFixture() throws -> (
        deps: ConversationRuntimeDependencies,
        services: HarnessRuntimeSessionFactory.Services,
        conversationID: UUID
    ) {
        let (deps, _) = try ReplayProjectionTestSupport.makeReplayProjectionDependencies()
        let services = ReplayProjectionTestSupport.makeReplayProjectionServices(deps: deps)
        return (deps, services, UUID())
    }

    private func seedAndSelect(
        deps: ConversationRuntimeDependencies,
        services: HarnessRuntimeSessionFactory.Services
    ) async throws -> UUID {
        let conversationID = try await ReplayProjectionTestSupport.seedConversation(
            deps: deps,
            extraMessages: [
                Message(id: UUID(), role: .user, content: "seed", timestamp: Date(), toolCalls: [])
            ]
        )
        try await services.conversationSelectionRuntimeService.selectConversation(conversationID: conversationID)
        return conversationID
    }

    @Test("rapid monotonic projection refresh keeps staleProjectionDropCount at zero")
    func monotonicRefreshChurnDoesNotIncrementStaleDrops() async throws {
        let (deps, services, _) = try makeFixture()
        let conversationID = try await seedAndSelect(deps: deps, services: services)
        let messaging = services.conversationMessagingRuntimeService
        let projection = services.contextProjectionService
        let base = Date()

        for index in 0..<15 {
            await messaging.appendMessagesToConversation(
                [Message(
                    id: UUID(),
                    role: .assistant,
                    content: "assistant-\(index)",
                    timestamp: base.addingTimeInterval(Double(index + 1)),
                    toolCalls: []
                )],
                conversationID: conversationID
            )
        }

        let metrics = await projection.projectionHardeningMetrics()
        #expect(metrics.staleProjectionDropCount == 0)
    }

    @Test("message stream receives updates during valid projection churn")
    func streamReceivesUpdatesDuringValidChurn() async throws {
        let (deps, services, _) = try makeFixture()
        let conversationID = try await seedAndSelect(deps: deps, services: services)
        let selection = services.conversationSelectionRuntimeService
        let messaging = services.conversationMessagingRuntimeService
        let projection = services.contextProjectionService
        let initial = await selection.currentMessages
        let streamPair = AsyncStream<[Message]>.makeStream()
        await selection.wireMessageStream(continuation: streamPair.continuation, initial: initial)

        let collector = Task {
            var counts: [Int] = []
            for await messages in streamPair.stream {
                counts.append(messages.count)
                if counts.count > 40 { break }
            }
            return counts
        }

        let base = Date()
        for index in 0..<12 {
            await messaging.appendMessagesToConversation(
                [Message(
                    id: UUID(),
                    role: .assistant,
                    content: "stream-\(index)",
                    timestamp: base.addingTimeInterval(Double(index + 1)),
                    toolCalls: []
                )],
                conversationID: conversationID
            )
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        collector.cancel()
        let observed = await collector.value
        await selection.cancelMessageStreamBridge()

        #expect(observed.count > 1)
        let peak = observed.max() ?? 0
        #expect(peak >= initial.count)
        let metrics = await projection.projectionHardeningMetrics()
        #expect(metrics.staleProjectionDropCount == 0)
    }

    @Test("stale projection apply suppresses stream publish and increments stale metric")
    func staleApplySuppressesStreamPublish() async throws {
        let (deps, services, _) = try makeFixture()
        let conversationID = try await seedAndSelect(deps: deps, services: services)
        let selection = services.conversationSelectionRuntimeService
        let messaging = services.conversationMessagingRuntimeService
        let projection = services.contextProjectionService
        let sessionProjection = services.sessionProjectionRuntimeService

        await messaging.appendMessagesToConversation(
            [Message(id: UUID(), role: .assistant, content: "visible", timestamp: Date(), toolCalls: [])],
            conversationID: conversationID
        )
        let beforeStale = await selection.currentMessages
        #expect(beforeStale.contains { $0.content == "visible" })

        let projectedHash = ConversationEventLogService.contentHash(for: beforeStale)
        await sessionProjection.testing_seedProjectionPublishState(
            conversationID: conversationID,
            frontierEventID: 99_999,
            contentHash: projectedHash
        )

        let metricsBefore = await projection.projectionHardeningMetrics()
        await messaging.refreshProjectedConversationMessages(conversationID: conversationID, baseMessagesOverride: nil)
        let metricsAfter = await projection.projectionHardeningMetrics()
        let afterStale = await selection.currentMessages

        #expect(metricsAfter.staleProjectionDropCount == metricsBefore.staleProjectionDropCount + 1)
        #expect(afterStale.map(\.content) == beforeStale.map(\.content))
    }
}
