import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Sub-agent tool approvals reach the user's conversation")
struct SubAgentApprovalRoutingTests {
    private static let toolName = ConversationsToolProvider.listConversationsToolName

    private static func session(callID: String) throws -> (HarnessRuntimeSession, Section6ConversationEventCapture) {
        let session = HarnessRuntimeSession(
            container: try section6Container(),
            toolPolicy: ToolPolicyConfiguration(
                approvalRequiredToolNames: [toolName],
                approvalTimeoutMilliseconds: 60_000
            ),
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedToolThenAnswerLLM(toolName: toolName, toolCallID: callID, finalAssistantText: "child done")
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        return (session, Section6ConversationEventCapture())
    }

    private static func child(of parentID: UUID, in session: HarnessRuntimeSession) async throws -> UUID {
        try await session.persistenceDomain.createIsolatedSubAgent(
            parentConversationID: parentID,
            selectedModel: section6Model(),
            userSystemPrompt: "child",
            topic: "child",
            description: nil,
            metadata: nil,
            interactionMode: .agent,
            modeProfileID: "subagent-general"
        ).id
    }

    private static func approvalRequests(_ publisher: Section6ConversationEventCapture, _ conversationID: UUID) async -> [RuntimeLifecycleEventPayload] {
        await publisher.runtimeLifecycleEvents(for: conversationID).filter { $0.name == .toolApprovalRequired && $0.toolName == toolName }
    }

    @Test("A sub-agent's approval card goes to its parent, and approving it there runs the sub-agent's call")
    func approvedInParent() async throws {
        let callID = "call_child_approval_1"
        let (session, publisher) = try Self.session(callID: callID)
        await session.setConversationTopicPublisher(publisher)
        try await session.createConversation(with: section6Model(), userSystemPrompt: "parent")
        let parentID = try #require(await session.currentConversationID)
        let childID = try await Self.child(of: parentID, in: session)

        let response = try await session.sendMessageAndStreamResponse("go", images: [], conversationID: childID)
        await waitUntil(timeoutMS: 10_000) { !(await Self.approvalRequests(publisher, parentID)).isEmpty }
        let request = try #require(await Self.approvalRequests(publisher, parentID).first)
        #expect(await Self.approvalRequests(publisher, childID).isEmpty)

        try await session.toolApprovalRuntimeService.resolveToolApprovalForAPI(
            conversationID: parentID,
            runID: request.runID,
            toolName: Self.toolName,
            route: .user,
            status: .approved,
            source: "test",
            reason: nil
        )
        await awaitStreamingRunSettled(session, response: response, timeoutMS: 15_000)

        let messages = try await session.listMessages(conversationID: childID)
        let result = try #require(messages.first { $0.role == .tool && $0.toolCallId == callID })
        #expect(!result.content.contains("denied"), "\(result.content)")
    }

    @Test("A sub-agent's unanswered approval still times out")
    func timesOut() async throws {
        let callID = "call_child_approval_timeout"
        let session = HarnessRuntimeSession(
            container: try section6Container(),
            toolPolicy: ToolPolicyConfiguration(
                approvalRequiredToolNames: [Self.toolName],
                approvalTimeoutMilliseconds: 1_000
            ),
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedToolThenAnswerLLM(toolName: Self.toolName, toolCallID: callID, finalAssistantText: "child done")
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await session.createConversation(with: section6Model(), userSystemPrompt: "parent")
        let parentID = try #require(await session.currentConversationID)
        let childID = try await Self.child(of: parentID, in: session)

        let response = try await session.sendMessageAndStreamResponse("go", images: [], conversationID: childID)
        await awaitStreamingRunSettled(session, response: response, timeoutMS: 15_000)
        let messages = try await session.listMessages(conversationID: childID)
        let result = try #require(messages.first { $0.role == .tool && $0.toolCallId == callID })
        #expect(result.content.contains("denied"), "\(result.content)")
    }
}
