#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime approval lifecycle")
struct AgentRuntimeApprovalLifecycleTests {
    @Test("approval-required tools emit runtime lifecycle audit events")
    func approvalRequiredToolsEmitRuntimeLifecycleAudit() async throws {
        let container = try section6Container()
        let model = section6Model()
        let toolCallID = "call_approval_audit_1"
        let manager = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                approvalRequiredToolNames: [ConversationsToolProvider.listConversationsToolName],
                approvalTimeoutMilliseconds: 200
            ),
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedToolThenAnswerLLM(
                    toolName: ConversationsToolProvider.listConversationsToolName,
                    toolCallID: toolCallID,
                    finalAssistantText: "done"
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: model, userSystemPrompt: "approval-audit")
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse("trigger approval policy", images: [], conversationID: conversationID)
        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let approvalRequired = lifecycle.first(where: {
            $0.name == .toolApprovalRequired && $0.toolName == ConversationsToolProvider.listConversationsToolName
        })
        #expect(approvalRequired != nil)
        #expect(approvalRequired?.approvalState == .pending)
        #expect(approvalRequired?.policyReason == ToolAvailabilityBlockReason.approvalRequired.rawValue)
        #expect(approvalRequired?.source == "runtime.toolDispatch")
        #expect(lifecycle.first?.name == .turnStarted)
        let terminalCount = lifecycle.filter {
            $0.name == .turnCompleted || $0.name == .turnCancelled || $0.name == .turnBounded
        }.count
        #expect(terminalCount == 1)

        let messages = try await manager.listMessages(conversationID: conversationID)
        let latestAssistant = try #require(messages.last(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }))
        for call in latestAssistant.toolCalls {
            let callID = try #require(call.id)
            #expect(messages.contains(where: { $0.role == .tool && $0.toolCallId == callID }))
        }
    }

    @Test("agent loop advertises approval-gated tools and surfaces lifecycle")
    func agentLoopApprovalGatedToolLifecycle() async throws {
        let container = try section6Container()
        let model = section6Model()
        let toolCallID = "call_legacy_approval_1"
        let manager = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                approvalRequiredToolNames: [ConversationsToolProvider.listConversationsToolName],
                approvalTimeoutMilliseconds: 200
            ),
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedToolThenAnswerLLM(
                    toolName: ConversationsToolProvider.listConversationsToolName,
                    toolCallID: toolCallID,
                    finalAssistantText: "approval done"
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: model, userSystemPrompt: "approval-audit")
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "trigger approval policy",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let approvalRequired = lifecycle.first(where: {
            $0.name == .toolApprovalRequired
                && $0.toolName == ConversationsToolProvider.listConversationsToolName
        })
        #expect(approvalRequired != nil)
        #expect(approvalRequired?.approvalState == .pending)
        #expect(approvalRequired?.policyReason == ToolAvailabilityBlockReason.approvalRequired.rawValue)
        let terminalCount = lifecycle.filter {
            $0.name == .turnCompleted || $0.name == .turnCancelled || $0.name == .turnBounded
        }.count
        #expect(terminalCount == 1)

        let messages = try await manager.listMessages(conversationID: conversationID)
        let latestAssistant = try #require(messages.last(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }))
        for call in latestAssistant.toolCalls {
            let callID = try #require(call.id)
            #expect(messages.contains(where: { $0.role == .tool && $0.toolCallId == callID }))
        }
    }

}
