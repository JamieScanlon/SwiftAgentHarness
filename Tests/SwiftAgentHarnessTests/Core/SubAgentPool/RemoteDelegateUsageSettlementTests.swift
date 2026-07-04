import Foundation
import SwiftAgentKit
import SwiftAgentKitACP
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("Remote delegate usage settlement")
struct RemoteDelegateUsageSettlementTests {
    actor MockACPStreamClientWithUsage: ACPAgentStreamClient {
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
            let updates = AsyncStream<ACPSessionUpdate> { continuation in
                continuation.yield(
                    .usageUpdate(
                        used: 42,
                        size: 4096,
                        cost: ACPUsageCost(amount: 0.0125, currency: "USD")
                    )
                )
                continuation.finish()
            }
            let response = Task { () throws -> ACPPromptResponse in
                ACPPromptResponse(stopReason: .endTurn)
            }
            return (updates, response)
        }

        func shutdown() async {}
    }

    @Test("terminal remote delegate completion settles explicit usage cost")
    func terminalRemoteDelegateSettlesExplicitCost() async throws {
        let ledger = ModelPoolCostLedger(defaultDelegateCompletionUSD: 0.25)
        let container = try HarnessTestModelContainer.makeInMemory()
        let host = HarnessRuntimeSession(
            container: container,
            delegateCostTracker: ledger,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "remote-delegate-settle-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        try await host.createConversation(with: model, userSystemPrompt: "remote-delegate-settle")
        let parentConversationID = try #require(await host.currentConversationID)

        let agentName = "delegate_acp_settle_\(UUID().uuidString.lowercased())"
        let manager = ACPManager()
        let mock = MockACPStreamClientWithUsage(
            agentInfo: ACPImplementation(name: agentName, title: "Settle Test ACP", version: "1.0.0")
        )
        try await manager.initialize(clients: [mock])
        await host.setACPManager(manager, delegateBoxes: [:])

        _ = try await host.subAgentSpawnService.spawnSubAgentViaPool(
            parentConversationID: parentConversationID,
            request: SubAgentSpawnRequest(
                context: .isolated,
                taskDescription: "Settle delegate usage",
                subagentType: SubAgentTransportKind.acpStdio.rawValue,
                agentID: agentName,
                runInBackground: true
            ),
            modelOverride: nil,
            bypassDelegateAllowList: true
        )

        await host.subAgentSpawnService.applySubAgentTransportPermissionResolutionIfNeeded(
            conversationID: parentConversationID,
            toolName: agentName,
            route: .user,
            status: .approved,
            source: "test.settlement"
        )

        var settledCost: Double?
        for _ in 0 ..< 100 {
            settledCost = await ledger.projectedCostUSD(conversationID: parentConversationID)
            if settledCost == 0.0125 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(settledCost == 0.0125)
    }
}
