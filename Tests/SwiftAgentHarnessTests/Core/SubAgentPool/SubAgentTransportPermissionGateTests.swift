import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Sub-agent transport permission gate")
struct SubAgentTransportPermissionGateTests {
    private func invocationRequest(
        permissionPolicy: SubAgentPermissionPolicy,
        permissionAlreadyGranted: Bool = false
    ) throws -> SubAgentTransportInvocationRequest {
        let agentID = "delegate_test_\(UUID().uuidString.lowercased())"
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: agentID, description: "test", parameters: [], type: .a2aAgent),
            source: .a2a,
            transportKind: .a2a
        )
        let registryEntry = SubAgentRegistryEntry(
            agentID: agentID,
            displayName: agentID,
            description: "test",
            delegateToolName: agentID,
            source: .a2a,
            transportKind: SubAgentTransportKind.a2a.rawValue,
            permissionPolicy: permissionPolicy,
            availableToolInfo: toolEntry.availableToolInfo
        )
        let pool = DefaultSubAgentPool()
        var metadata: JSON = .object([:])
        if permissionAlreadyGranted {
            metadata = .object(["permissionAlreadyGranted": .boolean(true)])
        }
        let launchPlan = try pool.planLaunch(
            SubAgentLaunchRequest(
                context: .isolated,
                subagentType: SubAgentTransportKind.a2a.rawValue,
                runInBackground: true,
                agentID: agentID,
                metadata: metadata
            ),
            parentConversationID: UUID()
        )
        return SubAgentTransportInvocationRequest(
            launchPlan: launchPlan,
            registryEntry: registryEntry,
            toolEntry: toolEntry,
            parentConversationID: UUID()
        )
    }

    @Test("askParent starts awaiting approval with parent route")
    func askParentAwaitingApproval() throws {
        let request = try invocationRequest(permissionPolicy: .askParent)
        #expect(SubAgentTransportPermissionGate.initialPhase(for: request) == .awaitingApproval)
        #expect(SubAgentTransportPermissionGate.initialApprovalRoute(for: request) == .parent)
    }

    @Test("askUser starts awaiting approval with user route")
    func askUserAwaitingApproval() throws {
        let request = try invocationRequest(permissionPolicy: .askUser)
        #expect(SubAgentTransportPermissionGate.initialPhase(for: request) == .awaitingApproval)
        #expect(SubAgentTransportPermissionGate.initialApprovalRoute(for: request) == .user)
    }

    @Test("auto policy runs immediately")
    func autoRunsImmediately() throws {
        let request = try invocationRequest(permissionPolicy: .auto)
        #expect(SubAgentTransportPermissionGate.initialPhase(for: request) == .running)
        #expect(SubAgentTransportPermissionGate.initialApprovalRoute(for: request) == nil)
    }

    @Test("pre-granted permission runs immediately")
    func preGrantedRunsImmediately() throws {
        let request = try invocationRequest(permissionPolicy: .askUser, permissionAlreadyGranted: true)
        #expect(SubAgentTransportPermissionGate.initialPhase(for: request) == .running)
    }
}
