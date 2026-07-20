import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("Provider tool schema normalization")
struct ProviderToolSchemaNormalizationTests {
    private func entry(
        name: String,
        schema: JSON,
        parameters: [ToolDefinition.Parameter] = []
    ) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(
                name: name,
                description: "desc",
                parameters: parameters,
                type: .function
            ),
            source: .local,
            canonicalParametersSchema: schema
        )
    }

    @Test("openAIStrict adds additionalProperties false and fills required")
    func openAIStrictShapesObject() {
        let schema: JSON = .object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object([
                    "type": .string("string"),
                    "description": .string("mode"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                ]),
            ]),
        ])
        let batch = ProviderToolSchemaTransform.normalize(
            entries: [entry(name: "search", schema: schema)],
            profile: ToolSchemaCompatProfile(toolSchemaMode: .openAIStrict)
        )
        #expect(batch.tools.count == 1)
        #expect(batch.strictByName["search"] == true)
        guard case .object(let output) = batch.parameterSchemasByName["search"],
              case .boolean(let additional) = output["additionalProperties"],
              case .object(let properties) = output["properties"],
              case .array(let required) = output["required"] else {
            Issue.record("expected strict-shaped schema")
            return
        }
        #expect(additional == false)
        #expect(properties.keys.contains("mode"))
        #expect(properties.keys.contains("limit"))
        #expect(Set(required.compactMap { if case .string(let name) = $0 { return name } else { return nil } }) == Set(["limit", "mode"]))
    }

    @Test("openAIStrict collapses constant anyOf to enum")
    func openAIStrictCollapsesEnum() {
        let schema: JSON = .object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object([
                    "anyOf": .array([
                        .object(["const": .string("fast")]),
                        .object(["const": .string("slow")]),
                    ]),
                ]),
            ]),
        ])
        let batch = ProviderToolSchemaTransform.normalize(
            entries: [entry(name: "mode_tool", schema: schema)],
            profile: ToolSchemaCompatProfile(toolSchemaMode: .openAIStrict)
        )
        guard case .object(let output) = batch.parameterSchemasByName["mode_tool"],
              case .object(let properties) = output["properties"],
              case .object(let mode) = properties["mode"],
              case .array(let enumValues) = mode["enum"] else {
            Issue.record("expected enum collapse")
            return
        }
        #expect(enumValues.count == 2)
        #expect(batch.diagnostics.contains(where: { $0.code == "union.collapsedToEnum" }))
    }

    @Test("openAIStrict omits tool and emits error for non-collapsible union")
    func openAIStrictOmitsUnsupportedUnion() {
        let schema: JSON = .object([
            "type": .string("object"),
            "properties": .object([
                "payload": .object([
                    "anyOf": .array([
                        .object([
                            "type": .string("object"),
                            "properties": .object([
                                "a": .object(["type": .string("string")]),
                            ]),
                        ]),
                        .object([
                            "type": .string("object"),
                            "properties": .object([
                                "b": .object(["type": .string("integer")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let batch = ProviderToolSchemaTransform.normalize(
            entries: [entry(name: "web_search", schema: schema)],
            profile: ToolSchemaCompatProfile(toolSchemaMode: .openAIStrict)
        )
        #expect(batch.tools.isEmpty)
        let diagnostic = batch.diagnostics.first(where: { $0.code == "union.unsupported" })
        #expect(diagnostic != nil)
        #expect(diagnostic?.logLine == "tool[web_search].parameters.properties.payload: anyOf/oneOf/allOf unsupported in strict OpenAI schema. (union.unsupported)")
    }

    @Test("grammarConstrained repairs bare object nodes")
    func grammarConstrainedRepairsBareObject() {
        let schema: JSON = .object([
            "type": .string("object"),
        ])
        let batch = ProviderToolSchemaTransform.normalize(
            entries: [entry(name: "bare", schema: schema)],
            profile: ToolSchemaCompatProfile(toolSchemaMode: .grammarConstrained)
        )
        guard case .object(let output) = batch.parameterSchemasByName["bare"],
              case .object = output["properties"] else {
            Issue.record("expected properties object")
            return
        }
        #expect(batch.diagnostics.contains(where: { $0.code == "malformed.bareObject" }))
    }

    @Test("registry entry carries canonical parameters schema from descriptor")
    func registryEntryCanonicalSchema() {
        let definition = ToolDefinition(
            name: "list_projects",
            description: "List projects",
            parameters: [.init(name: "limit", description: "Max rows", type: "integer", required: false)],
            type: .function
        )
        let normalizer = ToolSchemaNormalizer()
        let normalized = normalizer.normalize(
            rawSchema: definition.inferredSchemaJSON,
            source: .local,
            toolName: definition.name
        )
        let descriptor = RegisteredToolDescriptor(
            definition: definition,
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable,
            policyTags: [],
            normalizedSchema: normalized
        )
        let entry = OrchestrationToolCatalog.registryEntries(from: [descriptor]).first
        #expect(
            canonicalSchemaFingerprint(entry?.canonicalParametersSchema)
                == canonicalSchemaFingerprint(normalized.schema)
        )
    }

    private func canonicalSchemaFingerprint(_ schema: JSON?) -> String? {
        guard let schema else { return nil }
        return stableFingerprint(schema)
    }

    /// Order-independent fingerprint so Dictionary-backed JSON objects compare stably.
    private func stableFingerprint(_ value: JSON) -> String {
        switch value {
        case .boolean(let b):
            return b ? "true" : "false"
        case .integer(let n):
            return String(n)
        case .double(let n):
            return String(n)
        case .string(let s):
            return "\"\(s)\""
        case .array(let items):
            return "[" + items.map(stableFingerprint).joined(separator: ",") + "]"
        case .object(let dict):
            let pairs = dict.keys.sorted().map { key in
                "\"\(key)\":\(stableFingerprint(dict[key]!))"
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    @Test("ProviderRuntimeHooks resolves openAI strict profile from catalog compat")
    func runtimeHooksOpenAICompatProfile() throws {
        ProviderTestManifestSupport.activateProviderResources()
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: "openai")
        let gpt41 = try #require(entries.first { $0.endpointModelId == "gpt-4.1" })
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: gpt41.endpointModelId,
            serverURL: URL(string: "https://api.openai.com/v1")!
        )
        let profile = ProviderRuntimeHooks.toolSchemaCompatProfile(binding: binding, compat: gpt41.compat)
        #expect(profile.toolSchemaMode == .openAIStrict)
    }

    @Test("ProviderRuntimeHooks resolves grammar profile for ollama binding")
    func runtimeHooksOllamaGrammarProfile() {
        let binding = ProviderBinding(
            providerId: "ollama",
            modelProtocol: .ollama,
            endpointModelId: "llama3.2",
            serverURL: URL(string: "http://127.0.0.1:11434")!
        )
        let profile = ProviderRuntimeHooks.toolSchemaCompatProfile(binding: binding, compat: nil)
        #expect(profile.toolSchemaMode == .grammarConstrained)
    }

    @Test("OpenAI wire codec prefers schema map entry")
    func openAIWireCodecUsesSchemaMap() {
        let schema: JSON = .object([
            "type": .string("object"),
            "additionalProperties": .boolean(false),
            "properties": .object([
                "q": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("q")]),
        ])
        let tool = ToolDefinition(name: "search", description: "Search", parameters: [], type: .function)
        let function = tool.toOpenAIFunction(parameterSchema: schema, strict: true)
        #expect(function.strict == true)
        #expect(function.parameters != nil)
    }
}
