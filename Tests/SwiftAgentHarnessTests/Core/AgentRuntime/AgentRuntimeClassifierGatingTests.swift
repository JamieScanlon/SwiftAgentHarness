import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime classifier-assisted gating")
struct AgentRuntimeClassifierGatingTests {
    private let toolName = ConversationsToolProvider.listConversationsToolName

    private func session(gate: ToolApprovalClassifierGate?, toolCallID: String) throws -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: try section6Container(),
            toolPolicy: ToolPolicyConfiguration(
                approvalRequiredToolNames: [toolName],
                approvalTimeoutMilliseconds: 200
            ),
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedToolThenAnswerLLM(toolName: toolName, toolCallID: toolCallID, finalAssistantText: "done")
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence(),
            toolApprovalClassifierGate: gate
        )
    }

    private func gate(pClear: Double, counter: CallCounter = CallCounter()) -> ToolApprovalClassifierGate {
        var configuration = ToolApprovalClassifierConfiguration(policy: GatekeeperFixtures.policy())
        // Chat input in these fixtures carries no trust stamp.
        configuration.includeUnstampedUserMessages = true
        return ToolApprovalClassifierGate(
            dispatcher: GatekeeperFixtures.dispatcher(provider: GatekeeperFixtures.provider(pClear: pClear, counter: counter)),
            configuration: configuration
        )
    }

    private func run(_ manager: HarnessRuntimeSession) async throws -> (UUID, [RuntimeLifecycleEventPayload], [Message]) {
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: section6Model(), userSystemPrompt: "classifier-gate")
        let conversationID = try #require(await manager.currentConversationID)
        let response = try await manager.sendMessageAndStreamResponse(
            "list my recent conversations", images: [], conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)
        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let messages = try await manager.listMessages(conversationID: conversationID)
        return (conversationID, lifecycle, messages)
    }

    @Test("A clear verdict turns the ask into allow-once: no human prompt, the tool runs, the approval is labeled")
    func clearAutoApproves() async throws {
        let toolCallID = "call_classifier_clear"
        let gate = gate(pClear: 0.97)
        let manager = try session(gate: gate, toolCallID: toolCallID)
        let (_, lifecycle, messages) = try await run(manager)

        #expect(!lifecycle.contains { $0.name == .toolApprovalRequired && $0.toolName == toolName })
        let resolved = try #require(lifecycle.first { $0.name == .toolApprovalResolved && $0.toolName == toolName })
        #expect(resolved.approvalState == .approved)
        #expect(resolved.approvalSource == "classifier")
        #expect(resolved.approvalResolutionKind == "classifier")
        #expect(resolved.source == "runtime.approvalClassifier")
        #expect(resolved.approvalReason?.hasPrefix("classifier: clear") == true)
        #expect(resolved.approvalReason?.contains("receipt=") == true)

        let toolResult = try #require(messages.first { $0.role == .tool && $0.toolCallId == toolCallID })
        #expect(!toolResult.content.contains("Tool dispatch denied"))
        #expect(!toolResult.content.contains("approval pending"))

        let records = await gate.records
        #expect(records.count == 1)
        guard case .object(let state)? = records.first?.request?.state,
              case .array(let requests)? = state["user_request"] else {
            Issue.record("expected the user request in the classifier state")
            return
        }
        #expect(requests.contains { if case .string(let text) = $0 { text.contains("list my recent conversations") } else { false } })
    }

    @Test("A caution verdict leaves the call with the human")
    func cautionAsksHuman() async throws {
        let toolCallID = "call_classifier_caution"
        let gate = gate(pClear: 0.05)
        let manager = try session(gate: gate, toolCallID: toolCallID)
        let (_, lifecycle, _) = try await run(manager)

        let required = lifecycle.first { $0.name == .toolApprovalRequired && $0.toolName == toolName }
        #expect(required != nil)
        #expect(required?.source == "runtime.toolDispatch")
        #expect(!lifecycle.contains { $0.approvalSource == "classifier" })
        guard case .ask(.caution, _)? = await gate.records.first?.outcome else {
            Issue.record("expected a recorded caution ask")
            return
        }
    }

    @Test("Without a gate the approval path is unchanged")
    func noGateUnchanged() async throws {
        let manager = try session(gate: nil, toolCallID: "call_no_gate")
        let (_, lifecycle, _) = try await run(manager)
        #expect(lifecycle.contains { $0.name == .toolApprovalRequired && $0.toolName == toolName })
        #expect(!lifecycle.contains { $0.approvalSource == "classifier" })
    }

    @Test("Rule-blocked tools never reach the classifier, even when also approval-required")
    func denyRulesWin() async throws {
        let counter = CallCounter()
        let gate = gate(pClear: 0.99, counter: counter)
        let manager = HarnessRuntimeSession(
            container: try section6Container(),
            toolPolicy: ToolPolicyConfiguration(
                escalationRequiredToolNames: [toolName],
                approvalRequiredToolNames: [toolName]
            ),
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedToolThenAnswerLLM(toolName: toolName, toolCallID: "call_denied", finalAssistantText: "done")
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence(),
            toolApprovalClassifierGate: gate
        )
        let (_, lifecycle, _) = try await run(manager)
        #expect(!lifecycle.contains { $0.approvalSource == "classifier" })
        #expect(await counter.count == 0)
        #expect(await gate.records.isEmpty)
    }
}

@Suite("ToolApprovalRuntimeService classifier approval")
struct ToolApprovalRuntimeServiceClassifierTests {
    @Test("A cleared call is resolved allow-once with kind classifier and never becomes a durable grant")
    func allowOnceOnly() async throws {
        let gate = GatekeeperFixtures.gate(
            dispatcher: GatekeeperFixtures.dispatcher(provider: GatekeeperFixtures.provider(pClear: 0.98))
        )
        let manager = HarnessRuntimeSession(
            container: try section6Container(),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence(),
            toolApprovalClassifierGate: gate
        )
        try await manager.createConversation(with: section6Model(), userSystemPrompt: "classifier-service")
        let conversationID = try #require(await manager.currentConversationID)
        let service = await manager.services.toolApprovalRuntimeService
        let call = ToolCallRequest(id: "call_1", name: "list_conversations", arguments: .object(["limit": .integer(3)]))

        let approved = await service.classifierAutoApproval(
            conversationID: conversationID,
            runID: nil,
            call: call,
            route: .user,
            isElevated: false,
            transcript: [GatekeeperFixtures.userMessage("list my conversations")]
        )
        #expect(approved)
        let resolution = try #require(await service.toolApprovalResolution(
            conversationID: conversationID, runID: nil, binding: ToolCallApprovalBinding.from(call: call)
        ))
        #expect(resolution.status == .approved)
        #expect(resolution.kind == .classifier)
        #expect(resolution.decision == .allowOnce)
        #expect(resolution.source == "classifier")
        #expect(resolution.reason?.hasPrefix("classifier: clear") == true)
        #expect(await service.listDurableToolGrants(ownerAccountID: nil).isEmpty)

        let other = ToolCallRequest(id: "call_2", name: "list_conversations", arguments: .object(["limit": .integer(500)]))
        #expect(await service.toolApprovalResolution(
            conversationID: conversationID, runID: nil, binding: ToolCallApprovalBinding.from(call: other)
        ) == nil)
    }

    @Test("When the gatekeeper asks, nothing is registered or resolved")
    func askLeavesNoResolution() async throws {
        let gate = GatekeeperFixtures.gate(dispatcher: GatekeeperFixtures.dispatcher(provider: GatekeeperFixtures.provider(pClear: 0.6)))
        let manager = HarnessRuntimeSession(
            container: try section6Container(),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence(),
            toolApprovalClassifierGate: gate
        )
        try await manager.createConversation(with: section6Model(), userSystemPrompt: "classifier-service")
        let conversationID = try #require(await manager.currentConversationID)
        let service = await manager.services.toolApprovalRuntimeService
        let call = ToolCallRequest(id: "call_1", name: "list_conversations", arguments: .object([:]))
        let approved = await service.classifierAutoApproval(
            conversationID: conversationID, runID: nil, call: call, route: .user, isElevated: false,
            transcript: [GatekeeperFixtures.userMessage("list my conversations")]
        )
        #expect(!approved)
        #expect(await service.toolApprovalResolution(
            conversationID: conversationID, runID: nil, binding: ToolCallApprovalBinding.from(call: call)
        ) == nil)
    }

    @Test("With no gate configured the layer is off")
    func noGate() async throws {
        let manager = HarnessRuntimeSession(
            container: try section6Container(),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(with: section6Model(), userSystemPrompt: "classifier-service")
        let conversationID = try #require(await manager.currentConversationID)
        let service = await manager.services.toolApprovalRuntimeService
        let approved = await service.classifierAutoApproval(
            conversationID: conversationID, runID: nil,
            call: ToolCallRequest(id: "c", name: "list_conversations", arguments: .object([:])),
            route: .user, isElevated: false,
            transcript: [GatekeeperFixtures.userMessage("list")]
        )
        #expect(!approved)
    }
}
