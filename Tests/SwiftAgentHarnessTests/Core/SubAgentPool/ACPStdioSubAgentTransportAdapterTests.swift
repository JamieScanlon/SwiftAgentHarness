import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitACP
import Testing
@testable import SwiftAgentHarness

@Suite("ACP sub-agent delegate stream mapping")
struct SubAgentACPDelegateStreamMappingTests {
    private func session() -> RemoteTransportSession {
        RemoteTransportSession(
            correlation: SubAgentTransportInvocationCorrelation(
                lifecycleID: "lifecycle-1",
                transportKind: .acpStdio,
                sessionHandleID: "agent-1",
                completionHandleID: "handle-1"
            ),
            parentConversationID: UUID(),
            delegateToolName: "delegate_acp",
            defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            permissionPolicy: SubAgentPermissionPolicy.askUser.rawValue,
            status: .running
        )
    }

    @Test("completed maps to done with completion source")
    func completedMapsToDone() {
        var mapper = SubAgentACPDelegateStreamMapper()
        let mapped = mapper.map(
            event: .completed(content: "done text", stopReason: .endTurn, sessionID: "session-1"),
            session: session()
        )
        #expect(mapped?.phase == .done)
        #expect(mapped?.completionSource == "done text")
    }

    @Test("usageUpdate followed by completed attaches completion usage")
    func usageUpdateFollowedByCompletedAttachesUsage() {
        var mapper = SubAgentACPDelegateStreamMapper()
        _ = mapper.map(
            event: .usageUpdate(used: 120, size: 4096, cost: ACPUsageCost(amount: 0.02, currency: "USD")),
            session: session()
        )
        let mapped = mapper.map(
            event: .completed(content: "done text", stopReason: .endTurn, sessionID: "session-1"),
            session: session()
        )
        #expect(mapped?.completionUsage?.totalTokens == 120)
        #expect(mapped?.completionUsage?.costUSD == 0.02)
    }

    @Test("failed maps to failed phase")
    func failedMapsToFailed() {
        var mapper = SubAgentACPDelegateStreamMapper()
        let mapped = mapper.map(
            event: .failed(error: "boom", sessionID: nil),
            session: RemoteTransportSession(
                correlation: SubAgentTransportInvocationCorrelation(
                    lifecycleID: "lifecycle-1",
                    transportKind: .acpStdio,
                    sessionHandleID: "agent-1",
                    completionHandleID: nil
                ),
                parentConversationID: UUID(),
                delegateToolName: "delegate_acp",
                defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
                permissionPolicy: SubAgentPermissionPolicy.askUser.rawValue,
                status: .running
            )
        )
        #expect(mapped?.phase == .failed)
        #expect(mapped?.error == "boom")
    }
}

@Suite("ACP stdio sub-agent transport adapter")
struct ACPStdioSubAgentTransportAdapterTests {
    actor MockACPStreamClient: ACPAgentStreamClient {
        var agentInfo: ACPImplementation?
        var sessionId: String? = "session-1"

        init(agentInfo: ACPImplementation?) {
            self.agentInfo = agentInfo
        }

        func promptStream(_ instructions: String) async throws -> (
            updates: AsyncStream<ACPSessionUpdate>,
            response: Task<ACPPromptResponse, Error>
        ) {
            _ = instructions
            let updates = AsyncStream<ACPSessionUpdate> { $0.finish() }
            let response = Task { () throws -> ACPPromptResponse in
                ACPPromptResponse(stopReason: .endTurn)
            }
            return (updates, response)
        }

        func shutdown() async {}
    }

    @Test("invoke reaches done without synthetic usage")
    func invokeStreamsDoneFromManager() async throws {
        let agentName = "delegate_acp_\(UUID().uuidString.lowercased())"
        let manager = ACPManager()
        let mock = MockACPStreamClient(
            agentInfo: ACPImplementation(name: agentName, title: "Test ACP", version: "1.0.0")
        )
        try await manager.initialize(clients: [mock])

        let sessionStore = SubAgentRemoteTransportSessionStore()
        let provider = SubAgentPoolACPManagerProvider()
        await provider.setBootstrap(manager: manager)
        let pool = DefaultSubAgentPool(
            adapters: SubAgentDefaultAdapters.make(
                acpManagerProvider: provider,
                sessionStore: sessionStore
            )
        )
        let parentConversationID = UUID()
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentName, description: "remote", parameters: [], type: .acpAgent),
            source: .unknown,
            transportKind: .acp
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentName,
            displayName: agentName,
            description: "remote",
            delegateToolName: agentName,
            source: .unknown,
            transportKind: SubAgentTransportKind.acpStdio.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                taskDescription: "Run delegated work",
                subagentType: SubAgentTransportKind.acpStdio.rawValue,
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

    @Test("manager unavailable emits failed delegate event")
    func managerUnavailableFailsClosed() async throws {
        let pool = DefaultSubAgentPool()
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_acp_worker", description: "acp worker", parameters: [], type: .acpAgent),
            source: .unknown,
            executionEnvironment: .init(
                kind: .mcp,
                adapterID: SubAgentTransportKind.acpStdio.rawValue,
                isolationLevel: .remoteManaged
            )
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: "delegate_acp_worker",
            displayName: "delegate_acp_worker",
            description: "acp worker",
            delegateToolName: "delegate_acp_worker",
            source: .unknown,
            transportKind: SubAgentTransportKind.acpStdio.rawValue,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let parentConversationID = UUID()
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.acpStdio.rawValue,
                runInBackground: true,
                agentID: "delegate_acp_worker",
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
        let terminal = events.last { $0.phase == .failed }
        #expect(terminal?.error == "acp_manager_unavailable")
    }
}

@Suite("ACP terminal RPC translator")
struct ACPTerminalRPCTranslatorTests {
    @Test("shell command joins command and args")
    func shellCommandJoinsArgs() {
        let request = ACPCreateTerminalRequest(
            sessionId: "s1",
            command: "echo",
            args: ["hello"]
        )
        #expect(ACPTerminalRPCTranslator.shellCommand(from: request) == "echo 'hello'")
    }
}
