import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitA2A
import Testing
@testable import SwiftAgentHarness

@Suite("A2A sub-agent transport adapter")
struct A2ASubAgentTransportAdapterTests {
    actor MockA2AStreamClient: A2AAgentStreamClient {
        var agentCard: AgentCard?
        private let events: [SendStreamingMessageSuccessResponse<MessageResult>]

        init(agentCard: AgentCard?, events: [SendStreamingMessageSuccessResponse<MessageResult>]) {
            self.agentCard = agentCard
            self.events = events
        }

        func streamMessage(params: MessageSendParams) async throws -> AsyncStream<SendStreamingMessageSuccessResponse<MessageResult>> {
            let events = events
            return AsyncStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private func wrap(_ result: MessageResult) -> SendStreamingMessageSuccessResponse<MessageResult> {
        SendStreamingMessageSuccessResponse(jsonrpc: "2.0", id: 1, result: result)
    }

    private func mockAgentCard(name: String) -> AgentCard {
        AgentCard(
            name: name,
            description: "Test agent",
            url: "https://example.com/\(name)",
            version: "1.0.0",
            capabilities: AgentCard.AgentCapabilities(streaming: true),
            defaultInputModes: ["text/plain"],
            defaultOutputModes: ["text/plain"],
            skills: [
                AgentCard.AgentSkill(
                    id: "skill1",
                    name: "Test Skill",
                    description: "A test skill",
                    tags: ["test"]
                ),
            ]
        )
    }

    @Test("stream mapping maps completed delegate event to done")
    func streamMappingCompletedToDone() {
        let session = RemoteTransportSession(
            correlation: SubAgentTransportInvocationCorrelation(
                lifecycleID: "lifecycle-1",
                transportKind: .a2a,
                sessionHandleID: "agent-1",
                completionHandleID: "handle-1"
            ),
            parentConversationID: UUID(),
            delegateToolName: "delegate_agent",
            defaultTrustLevel: SubAgentTrustLevel.knownParty.rawValue,
            permissionPolicy: SubAgentPermissionPolicy.auto.rawValue,
            status: .running
        )
        let mapped = SubAgentA2ADelegateStreamMapping.map(
            event: .completed(A2ADelegateCompletion(content: "result text", metadata: nil, taskID: "task-1", contextID: "ctx-1")),
            session: session
        )
        #expect(mapped?.phase == .done)
        #expect(mapped?.completionSource == "result text")
        #expect(mapped?.completionUsage == nil)
    }

    @Test("stream mapping maps completion metadata to completion usage")
    func streamMappingMapsCompletionMetadata() {
        let session = RemoteTransportSession(
            correlation: SubAgentTransportInvocationCorrelation(
                lifecycleID: "lifecycle-2",
                transportKind: .a2a,
                sessionHandleID: "agent-1",
                completionHandleID: "handle-2"
            ),
            parentConversationID: UUID(),
            delegateToolName: "delegate_agent",
            defaultTrustLevel: SubAgentTrustLevel.knownParty.rawValue,
            permissionPolicy: SubAgentPermissionPolicy.auto.rawValue,
            status: .running
        )
        let metadata = LLMMetadata(promptTokens: 80, completionTokens: 20, totalTokens: 100)
        let mapped = SubAgentA2ADelegateStreamMapping.map(
            event: .completed(A2ADelegateCompletion(content: "done", metadata: metadata, taskID: "task-2", contextID: "ctx-2")),
            session: session
        )
        #expect(mapped?.completionUsage?.promptTokens == 80)
        #expect(mapped?.completionUsage?.completionTokens == 20)
        #expect(mapped?.completionUsage?.totalTokens == 100)
    }

    @Test("invoke reaches done without synthetic usage")
    func invokeStreamsDoneFromManager() async throws {
        let agentName = "delegate_a2a_\(UUID().uuidString.lowercased())"
        let taskID = UUID().uuidString
        let contextID = UUID().uuidString
        let task = A2ATask(
            id: taskID,
            contextId: contextID,
            status: TaskStatus(state: .working, timestamp: ISO8601DateFormatter().string(from: Date())),
            artifacts: nil
        )
        let artifactUpdate = TaskArtifactUpdateEvent(
            taskId: taskID,
            contextId: contextID,
            artifact: Artifact(
                artifactId: UUID().uuidString,
                parts: [.text(text: "delegate result")]
            ),
            append: true,
            lastChunk: true
        )
        let statusUpdate = TaskStatusUpdateEvent(
            taskId: taskID,
            contextId: contextID,
            status: TaskStatus(state: .completed, timestamp: ISO8601DateFormatter().string(from: Date())),
            final: true
        )
        let manager = A2AManager()
        let mock = MockA2AStreamClient(
            agentCard: mockAgentCard(name: agentName),
            events: [
                wrap(.task(task)),
                wrap(.taskArtifactUpdate(artifactUpdate)),
                wrap(.taskStatusUpdate(statusUpdate)),
            ]
        )
        try await manager.initialize(clients: [mock])

        let sessionStore = SubAgentRemoteTransportSessionStore()
        let provider = SubAgentPoolA2AManagerProvider()
        await provider.setManager(manager)
        let pool = DefaultSubAgentPool(
            adapters: SubAgentDefaultAdapters.make(
                a2aManagerProvider: provider,
                sessionStore: sessionStore
            )
        )
        let parentConversationID = UUID()
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentName, description: "remote", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentName,
            displayName: agentName,
            description: "remote",
            delegateToolName: agentName,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                taskDescription: "Run delegated work",
                subagentType: SubAgentTransportKind.a2a.rawValue,
                agentID: agentName,
                permissionAlreadyGranted: true
            ),
            parentConversationID: parentConversationID
        )
        let invokeResult = try await pool.invokeSubAgent(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: parentConversationID
        )
        guard case let .remoteStarted(correlation) = invokeResult.outcome else {
            Issue.record("Expected remoteStarted")
            return
        }
        let stream = await pool.streamDelegateEvents(
            SubAgentTransportDelegateEventsRequest(
                correlation: correlation,
                parentConversationID: parentConversationID
            )
        )
        var events: [SubAgentDelegateEvent] = []
        for await event in stream {
            events.append(event)
        }
        let terminal = events.last { $0.phase == .done || $0.phase == .failed }
        #expect(terminal?.phase == .done)
        #expect(terminal?.completionUsage == nil)
    }
}
