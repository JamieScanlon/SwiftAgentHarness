import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("InProcessLocalAgentToolProvider")
struct InProcessLocalAgentToolProviderTests {
    private func makeDefinition(
        toolName: String = "delegate_coding_agent",
        displayName: String = "Coding Agent",
        toolsAllow: [String]? = nil
    ) -> LocalAgentDefinition {
        LocalAgentDefinition(
            toolName: toolName,
            displayName: displayName,
            description: "In-process coding delegate for repo read/write and shell work.",
            modeProfileID: "coding-agent",
            modelRef: "qwen/qwen3-coder-30b",
            toolsAllow: toolsAllow
        )
    }

    /// Mirrors the registration pipeline: provider descriptor hints -> registry entry.
    private func makeRegistryEntry(for definition: LocalAgentDefinition) async -> ToolRegistryEntry {
        let provider = InProcessLocalAgentToolProvider(definitions: [definition])
        let toolDefinition = await provider.availableTools()[0]
        let normalizer = ToolSchemaNormalizer()
        let normalized = normalizer.normalize(rawSchema: toolDefinition.inferredSchemaJSON, source: .local)
        let descriptor = RegisteredToolDescriptor(
            definition: toolDefinition,
            source: .local,
            effectClass: .mutating,
            parallelHint: .parallelizable,
            policyTags: await provider.policyTags(for: toolDefinition),
            normalizedSchema: normalized
        )
        return ToolRegistryEntry(descriptor: descriptor)
    }

    // MARK: - Published schema

    @Test("Publishes one function tool per definition, in tool-name order")
    func publishesOneToolPerDefinition() async {
        let provider = InProcessLocalAgentToolProvider(definitions: [
            makeDefinition(toolName: "delegate_zeta", displayName: "Zeta"),
            makeDefinition(toolName: "delegate_alpha", displayName: "Alpha"),
        ])
        let tools = await provider.availableTools()
        #expect(tools.map(\.name) == ["delegate_alpha", "delegate_zeta"])
        #expect(tools.allSatisfy { $0.type == .function })
    }

    @Test("Schema is required instructions plus optional description")
    func exposesInstructionsAndDescription() async {
        let provider = InProcessLocalAgentToolProvider(definitions: [makeDefinition()])
        let parameters = await provider.availableTools()[0].parameters
        #expect(parameters.map(\.name).sorted() == ["description", "instructions"])
        let instructions = parameters.first { $0.name == "instructions" }
        let description = parameters.first { $0.name == "description" }
        #expect(instructions?.required == true)
        #expect(instructions?.type == "string")
        #expect(description?.required == false)
    }

    @Test("Tool description names the agent and warns that the delegate has no shared context")
    func describesFreshContext() async {
        let provider = InProcessLocalAgentToolProvider(definitions: [makeDefinition()])
        let description = await provider.availableTools()[0].description
        #expect(description.contains("Coding Agent"))
        #expect(description.contains("In-process coding delegate"))
        #expect(description.contains("cannot see this conversation"))
    }

    @Test("An empty definition set publishes nothing")
    func publishesNothingWhenEmpty() async {
        let provider = InProcessLocalAgentToolProvider(definitions: [])
        #expect(await provider.availableTools().isEmpty)
    }

    // MARK: - Registry classification

    @Test("Registry entry resolves to the local in-process execution environment")
    func resolvesInProcessExecutionEnvironment() async {
        let entry = await makeRegistryEntry(for: makeDefinition())
        #expect(entry.executionEnvironment.kind == .local)
        #expect(entry.executionEnvironment.adapterID == SubAgentTransportKind.inProcess.rawValue)
        #expect(entry.executionEnvironment.isolationLevel == .inProcess)
    }

    @Test("Registry entry carries exact-content and compaction protection")
    func carriesDelegateResultProtection() async {
        let entry = await makeRegistryEntry(for: makeDefinition())
        #expect(entry.policyTags.contains(.exactContentObservation))
        #expect(entry.policyTags.contains(.compactionProtected))
    }

    @Test("The Sub-Agent Pool classifies the generated tool as a delegate without a name allowlist")
    func poolClassifiesAsDelegate() async {
        let pool = DefaultSubAgentPool(hostingPolicyConfiguration: .empty)
        let entry = await makeRegistryEntry(for: makeDefinition())
        #expect(pool.isDelegateTool(entry: entry))
        #expect(pool.permissionPolicy(for: entry) == .askParent)
        #expect(pool.trustLevel(for: entry) == .system)
    }

    @Test("A non-delegate local tool is still not classified as a delegate")
    func doesNotOverclassify() async {
        let pool = DefaultSubAgentPool(hostingPolicyConfiguration: .empty)
        let definition = ToolDefinition(name: "read_file", description: "Read a file.", parameters: [], type: .function)
        let normalizer = ToolSchemaNormalizer()
        let descriptor = RegisteredToolDescriptor(
            definition: definition,
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable,
            policyTags: [],
            normalizedSchema: normalizer.normalize(rawSchema: definition.inferredSchemaJSON, source: .local)
        )
        #expect(pool.isDelegateTool(entry: ToolRegistryEntry(descriptor: descriptor)) == false)
    }

    // MARK: - Dispatch interception

    @Test("Reaching provider execution is an error, not a silent empty result")
    func executionIsUnreachable() async {
        let provider = InProcessLocalAgentToolProvider(definitions: [makeDefinition()])
        let call = ToolCall(
            name: "delegate_coding_agent",
            arguments: .object(["instructions": .string("do the thing")]),
            id: "call-1"
        )
        await #expect(throws: InProcessLocalAgentToolProvider.Error.self) {
            _ = try await provider.executeTool(call)
        }
    }
}
