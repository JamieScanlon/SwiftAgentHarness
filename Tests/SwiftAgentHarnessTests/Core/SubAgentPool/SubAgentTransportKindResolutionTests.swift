import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// `SubAgentTransportKind.resolve(for:)` is the single classifier behind registry rows, adapter
/// selection, permission/trust defaults and model-turn dispatch. When two call sites classified
/// independently, an MCP-sourced `delegate_*` tool was routed to ACP by the Pool while the spawn
/// service treated it as in-process — these cases pin the agreement.
@Suite("Sub-agent transport classification")
struct SubAgentTransportKindResolutionTests {
    private func entry(
        name: String = "delegate_thing",
        source: ToolListingSource,
        transportKind: ToolRegistryEntry.TransportKind,
        executionEnvironment: ToolRegistryEntry.ExecutionEnvironmentDescriptor? = nil,
        type: ToolDefinition.ToolType = .function
    ) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "d", parameters: [], type: type),
            source: source,
            transportKind: transportKind,
            executionEnvironment: executionEnvironment
        )
    }

    // MARK: - Precedence

    @Test("An explicit adapter id wins over every other signal")
    func adapterIDWins() {
        let resolved = SubAgentTransportKind.resolve(
            for: entry(
                source: .mcp,
                transportKind: .mcp,
                executionEnvironment: .init(kind: .mcp, adapterID: "in-process", isolationLevel: .inProcess)
            )
        )
        #expect(resolved == .inProcess)
    }

    @Test("Local tools published by the local-agent provider resolve to in-process")
    func localAgentProviderToolsResolveInProcess() {
        let definition = LocalAgentDefinition(
            toolName: "delegate_coding_agent",
            displayName: "Coding Agent",
            description: "d",
            modeProfileID: "subagent-minimal",
            modelRef: "test/model"
        )
        let tags = InProcessLocalAgentToolProvider.policyTags(for: definition)
        let normalizer = ToolSchemaNormalizer()
        let toolDefinition = ToolDefinition(
            name: definition.toolName,
            description: "d",
            parameters: [],
            type: .function
        )
        let registryEntry = ToolRegistryEntry(
            descriptor: RegisteredToolDescriptor(
                definition: toolDefinition,
                source: .local,
                effectClass: .mutating,
                parallelHint: .parallelizable,
                policyTags: tags,
                normalizedSchema: normalizer.normalize(rawSchema: toolDefinition.inferredSchemaJSON, source: .local)
            )
        )
        #expect(SubAgentTransportKind.resolve(for: registryEntry) == .inProcess)
    }

    // MARK: - The divergence this classifier exists to remove

    @Test("An MCP-sourced delegate tool resolves to ACP, not in-process")
    func mcpDelegateResolvesToACP() {
        // Default MCP execution environment: adapterID "tool-env.mcp.default" does not parse as a
        // transport kind. The old spawn-service copy fell back to .inProcess here.
        let resolved = SubAgentTransportKind.resolve(for: entry(source: .mcp, transportKind: .mcp))
        #expect(resolved == .acpStdio)
    }

    @Test("The Pool and the model-turn dispatch path agree on every source")
    func poolAndDispatchAgree() {
        let pool = DefaultSubAgentPool(hostingPolicyConfiguration: .empty)
        let cases: [ToolRegistryEntry] = [
            entry(source: .local, transportKind: .local),
            entry(source: .mcp, transportKind: .mcp),
            entry(source: .a2a, transportKind: .a2a),
            entry(source: .unknown, transportKind: .acp),
            entry(source: .unknown, transportKind: .unknown),
        ]
        for candidate in cases {
            let classified = SubAgentTransportKind.resolve(for: candidate)
            // The Pool's permission/trust defaults are derived from its own classification; if the
            // two ever diverge again these mappings stop lining up.
            let expectedPermission: SubAgentPermissionPolicy = switch classified {
            case .inProcess: .askParent
            case .a2a, .acpStdio, .customEndpoint, .unknown: .askUser
            }
            let expectedTrust: SubAgentTrustLevel = switch classified {
            case .inProcess: .system
            case .a2a: .knownParty
            case .acpStdio, .customEndpoint, .unknown: .unknownParty
            }
            #expect(pool.permissionPolicy(for: candidate) == expectedPermission)
            #expect(pool.trustLevel(for: candidate) == expectedTrust)
        }
    }

    // MARK: - Contradictory entries resolve toward the more-restrictive transport

    @Test("An a2aAgent definition with a local execution environment resolves to A2A, not in-process")
    func contradictoryEntryFailsSafe() {
        // `isDelegateTool` and `ToolRegistryEntry.augmentedPolicyTags` both treat `.a2aAgent` as
        // authoritative, tagging such entries exact-content/compaction-protected — i.e. untrusted
        // external output. Resolving the same entry to `.inProcess` would hand it `.system` trust
        // and `.askParent` permissions, so a contradiction must resolve toward the remote transport.
        let contradictory = entry(source: .local, transportKind: .local, type: .a2aAgent)
        #expect(SubAgentTransportKind.resolve(for: contradictory) == .a2a)

        let pool = DefaultSubAgentPool(hostingPolicyConfiguration: .empty)
        #expect(pool.trustLevel(for: contradictory) != .system)
        #expect(pool.permissionPolicy(for: contradictory) == .askUser)
    }

    @Test("An explicit adapter id still overrides a contradictory definition type")
    func adapterIDOverridesContradiction() {
        // Operator-declared routing metadata is deliberate; the definition type is a provider hint.
        let resolved = SubAgentTransportKind.resolve(
            for: entry(
                source: .local,
                transportKind: .local,
                executionEnvironment: .init(
                    kind: .local,
                    adapterID: SubAgentTransportKind.customEndpoint.rawValue,
                    isolationLevel: .inProcess
                ),
                type: .a2aAgent
            )
        )
        #expect(resolved == .customEndpoint)
    }

    // MARK: - Declared transport and definition type

    @Test("A2A is recognised from source, transport or definition type")
    func recognisesA2A() {
        #expect(SubAgentTransportKind.resolve(for: entry(source: .a2a, transportKind: .unknown)) == .a2a)
        #expect(SubAgentTransportKind.resolve(for: entry(source: .unknown, transportKind: .a2a)) == .a2a)
        #expect(
            SubAgentTransportKind.resolve(
                for: entry(source: .unknown, transportKind: .unknown, type: .a2aAgent)
            ) == .a2a
        )
    }

    @Test("ACP is recognised from transport or definition type")
    func recognisesACP() {
        #expect(SubAgentTransportKind.resolve(for: entry(source: .unknown, transportKind: .acp)) == .acpStdio)
        #expect(
            SubAgentTransportKind.resolve(
                for: entry(source: .unknown, transportKind: .unknown, type: .acpAgent)
            ) == .acpStdio
        )
    }

    @Test("An unclassifiable tool stays unknown rather than defaulting to in-process")
    func unknownStaysUnknown() {
        let resolved = SubAgentTransportKind.resolve(
            for: entry(
                source: .unknown,
                transportKind: .unknown,
                executionEnvironment: .init(kind: .unknown, adapterID: "tool-env.unknown.default", isolationLevel: .unknown)
            )
        )
        #expect(resolved == .unknown)
    }

    @Test("Docker and ssh execution environments are in-process delegates to the host")
    func containerEnvironmentsResolveInProcess() {
        for kind in [ToolRegistryEntry.ExecutionEnvironmentKind.docker, .ssh, .local] {
            let resolved = SubAgentTransportKind.resolve(
                for: entry(
                    source: .local,
                    transportKind: .local,
                    executionEnvironment: .init(kind: kind, adapterID: "tool-env.local.default", isolationLevel: .inProcess)
                )
            )
            #expect(resolved == .inProcess)
        }
    }
}
