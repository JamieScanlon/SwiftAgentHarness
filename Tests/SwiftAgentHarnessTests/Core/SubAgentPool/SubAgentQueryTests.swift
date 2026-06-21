import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgent query resolver")
struct SubAgentQueryTests {
    @Test("rank is deterministic for matching candidates")
    func deterministicRanking() {
        let entries: [SubAgentRegistryEntry] = [
            SubAgentRegistryEntry(
                agentID: "delegate_remote_alpha",
                displayName: "Remote Alpha",
                description: "General research delegate",
                delegateToolName: "delegate_remote_alpha",
                source: .a2a,
                transportKind: "a2a",
                useClasses: ["remote"],
                maxRecursionDepth: nil,
                streaming: true,
                longRunning: true,
                defaultTrustLevel: .knownParty,
                permissionPolicy: .askUser,
                availableToolInfo: .init(name: "delegate_remote_alpha", description: "a", source: .a2a)
            ),
            SubAgentRegistryEntry(
                agentID: "delegate_remote_beta",
                displayName: "Remote Beta",
                description: "Research and synthesis",
                delegateToolName: "delegate_remote_beta",
                source: .a2a,
                transportKind: "a2a",
                useClasses: ["remote"],
                maxRecursionDepth: nil,
                streaming: true,
                longRunning: true,
                defaultTrustLevel: .knownParty,
                permissionPolicy: .askUser,
                availableToolInfo: .init(name: "delegate_remote_beta", description: "b", source: .a2a)
            ),
        ]
        let query = SubAgentQuery(text: "research", transportKinds: ["a2a"])
        let first = SubAgentReferenceResolver.rank(query: query, in: entries).map(\.agentID)
        let second = SubAgentReferenceResolver.rank(query: query, in: entries).map(\.agentID)
        #expect(first == second)
    }

    @Test("filtering excludes non-matching transport")
    func filteringByTransport() {
        let entries: [SubAgentRegistryEntry] = [
            SubAgentRegistryEntry(
                agentID: "delegate_local_codegen",
                displayName: "Local Codegen",
                description: "Local codegen",
                delegateToolName: "delegate_local_codegen",
                source: .local,
                transportKind: "in-process",
                useClasses: ["local"],
                maxRecursionDepth: nil,
                streaming: true,
                longRunning: true,
                defaultTrustLevel: .system,
                permissionPolicy: .askParent,
                availableToolInfo: .init(name: "delegate_local_codegen", description: "local", source: .local)
            ),
        ]
        let query = SubAgentQuery(transportKinds: ["a2a"])
        let ranked = SubAgentReferenceResolver.rank(query: query, in: entries)
        #expect(ranked.isEmpty)
    }

    @Test("filtering respects hosted persona and auth scope tags")
    func filteringByHostPersonaAndAuthScopes() {
        let entries: [SubAgentRegistryEntry] = [
            SubAgentRegistryEntry(
                agentID: "delegate_scoped",
                displayName: "Scoped Delegate",
                description: "Scoped delegate",
                delegateToolName: "delegate_scoped",
                source: .a2a,
                transportKind: "a2a",
                useClasses: ["remote"],
                maxRecursionDepth: nil,
                streaming: true,
                longRunning: true,
                defaultTrustLevel: .knownParty,
                permissionPolicy: .askUser,
                hostingPolicy: SubAgentHostingPolicy(
                    hostPersonaID: "coding-agent",
                    delegationAllowlist: [],
                    authScopeTags: ["repo:write", "repo:read"],
                    routingDomain: "engineering",
                    tenantScope: "default"
                ),
                availableToolInfo: .init(name: "delegate_scoped", description: "scoped", source: .a2a)
            )
        ]
        let query = SubAgentQuery(
            hostPersonaID: "coding-agent",
            authScopeTags: ["repo:write"],
            routingDomain: "engineering",
            tenantScope: "default"
        )
        let ranked = SubAgentReferenceResolver.rank(query: query, in: entries)
        #expect(ranked.count == 1)
        #expect(ranked[0].agentID == "delegate_scoped")
    }
}
