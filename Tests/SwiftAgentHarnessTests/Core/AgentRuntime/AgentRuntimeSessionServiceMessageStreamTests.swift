import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntimeSessionService message stream")
struct AgentRuntimeSessionServiceMessageStreamTests {
    private func makeFixture() async throws -> (
        deps: ConversationRuntimeDependencies,
        services: HarnessRuntimeSessionFactory.Services,
        conversationID: UUID
    ) {
        let (deps, _) = try ReplayProjectionTestSupport.makeReplayProjectionDependencies()
        let services = ReplayProjectionTestSupport.makeReplayProjectionServices(deps: deps)
        let conversationID = try await ReplayProjectionTestSupport.seedConversation(
            deps: deps,
            extraMessages: [
                Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), toolCalls: [])
            ]
        )
        try await services.conversationSelectionRuntimeService.selectConversation(conversationID: conversationID)
        return (deps, services, conversationID)
    }

    @Test("buildRuntimeMessageStream yields initial projected messages")
    func initialYieldMatchesProjectedMessages() async throws {
        let (deps, services, conversationID) = try await makeFixture()
        let selection = services.conversationSelectionRuntimeService
        let agent = services.agentRuntimeSessionService
        let conversation = try #require(await deps.persistenceDomain.modelConversation(id: conversationID))
        let expected = await selection.projectedMessages(for: conversation)

        let stream = try await agent.buildRuntimeMessageStream(for: conversationID)
        var iterator = stream.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.map(\.content) == expected.map(\.content))
        await agent.cancelRuntimeMessageStream()
    }

    @Test("buildRuntimeMessageStream yields updates after projection refresh")
    func subsequentYieldAfterProjectionRefresh() async throws {
        let (_, services, conversationID) = try await makeFixture()
        let agent = services.agentRuntimeSessionService
        let messaging = services.conversationMessagingRuntimeService

        let stream = try await agent.buildRuntimeMessageStream(for: conversationID)
        var iterator = stream.makeAsyncIterator()
        _ = try #require(await iterator.next())

        await messaging.appendMessagesToConversation(
            [Message(id: UUID(), role: .assistant, content: "follow-up", timestamp: Date(), toolCalls: [])],
            conversationID: conversationID
        )

        let updated = try #require(await iterator.next())
        #expect(updated.contains { $0.content == "follow-up" })
        await agent.cancelRuntimeMessageStream()
    }

    @Test("replacing message stream finishes prior continuation")
    func replacingStreamFinishesPriorContinuation() async throws {
        let (_, services, conversationID) = try await makeFixture()
        let agent = services.agentRuntimeSessionService

        let firstStream = try await agent.buildRuntimeMessageStream(for: conversationID)
        let finished = Task {
            var iterator = firstStream.makeAsyncIterator()
            _ = await iterator.next()
            return await iterator.next()
        }

        _ = try await agent.buildRuntimeMessageStream(for: conversationID)
        let nextAfterReplace = await finished.value
        #expect(nextAfterReplace == nil)
        await agent.cancelRuntimeMessageStream()
    }

    @Test("cancelRuntimeMessageStream ends the active stream")
    func cancelEndsActiveStream() async throws {
        let (_, services, conversationID) = try await makeFixture()
        let agent = services.agentRuntimeSessionService

        let stream = try await agent.buildRuntimeMessageStream(for: conversationID)
        var iterator = stream.makeAsyncIterator()
        _ = try #require(await iterator.next())
        await agent.cancelRuntimeMessageStream()
        let afterCancel = await iterator.next()
        #expect(afterCancel == nil)
    }
}
