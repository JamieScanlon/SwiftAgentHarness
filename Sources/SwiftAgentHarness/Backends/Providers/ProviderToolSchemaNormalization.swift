import EasyJSON
import Foundation
import SwiftAgentKit

public struct ProviderToolSchemaBatchResult: Sendable {
    public let tools: [ToolDefinition]
    public let parameterSchemasByName: [String: JSON]
    public let strictByName: [String: Bool]
    public let diagnostics: [ToolSchemaNormalizationDiagnostic]

    public init(
        tools: [ToolDefinition],
        parameterSchemasByName: [String: JSON],
        strictByName: [String: Bool],
        diagnostics: [ToolSchemaNormalizationDiagnostic]
    ) {
        self.tools = tools
        self.parameterSchemasByName = parameterSchemasByName
        self.strictByName = strictByName
        self.diagnostics = diagnostics
    }

    public static let empty = ProviderToolSchemaBatchResult(
        tools: [],
        parameterSchemasByName: [:],
        strictByName: [:],
        diagnostics: []
    )
}

/// Provider-specific JSON Schema transforms at dispatch time (deep copy; registry entries stay pristine).
public enum ProviderToolSchemaTransform {
    private static let grammarUnsupportedKeywords: Set<String> = [
        "pattern",
        "minLength",
        "maxLength",
        "minimum",
        "maximum",
        "multipleOf",
        "minItems",
        "maxItems",
        "uniqueItems",
        "minProperties",
        "maxProperties",
    ]

    static func normalize(
        entries: [ToolRegistryEntry],
        profile: ToolSchemaCompatProfile
    ) -> ProviderToolSchemaBatchResult {
        var tools: [ToolDefinition] = []
        var parameterSchemasByName: [String: JSON] = [:]
        var strictByName: [String: Bool] = [:]
        var diagnostics: [ToolSchemaNormalizationDiagnostic] = []

        for entry in entries {
            let canonical = entry.canonicalParametersSchema ?? entry.definition.inferredSchemaJSON
            var collector = TransformCollector(toolName: entry.name)
            let transformed = transformNode(
                deepCopy(canonical),
                fieldPath: "parameters",
                profile: profile,
                collector: &collector
            )
            if collector.hasBlockingError {
                diagnostics.append(contentsOf: collector.diagnostics)
                continue
            }
            tools.append(entry.definition)
            parameterSchemasByName[entry.name] = transformed
            if profile.toolSchemaMode == .openAIStrict {
                strictByName[entry.name] = true
            }
            diagnostics.append(contentsOf: collector.diagnostics)
        }

        return ProviderToolSchemaBatchResult(
            tools: tools,
            parameterSchemasByName: parameterSchemasByName,
            strictByName: strictByName,
            diagnostics: diagnostics
        )
    }

    // MARK: - Profile transforms

    private static func transformNode(
        _ node: JSON,
        fieldPath: String,
        profile: ToolSchemaCompatProfile,
        collector: inout TransformCollector
    ) -> JSON {
        switch profile.toolSchemaMode {
        case .permissive:
            return node
        case .openAIStrict:
            return transformOpenAIStrict(node, fieldPath: fieldPath, collector: &collector)
        case .grammarConstrained:
            return transformGrammarConstrained(node, fieldPath: fieldPath, collector: &collector)
        case .googleStripped:
            return transformGoogleStripped(
                node,
                fieldPath: fieldPath,
                keywordsToStrip: profile.stripKeywords ?? [],
                collector: &collector
            )
        }
    }

    private static func transformOpenAIStrict(
        _ node: JSON,
        fieldPath: String,
        collector: inout TransformCollector
    ) -> JSON {
        if case .string(let stringValue) = node,
           let data = stringValue.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSON.self, from: data),
           case .object = parsed {
            collector.emit(
                fieldPath: fieldPath,
                code: "malformed.stringNode",
                message: "Schema node was a JSON string; parsed to object.",
                severity: .warning
            )
            return transformOpenAIStrict(parsed, fieldPath: fieldPath, collector: &collector)
        }

        guard case .object(var object) = node else {
            return node
        }

        if let type = object["type"] {
            switch type {
            case .array(let values):
                let typeStrings = values.compactMap { value -> String? in
                    guard case .string(let text) = value else { return nil }
                    return text
                }
                let nonNull = typeStrings.filter { $0 != "null" }
                if typeStrings.contains("null") {
                    collector.emit(
                        fieldPath: fieldPath,
                        code: "nullable.flattened",
                        message: "Flattened nullable type array for strict OpenAI schema.",
                        severity: .warning
                    )
                    object["x-nullable"] = .boolean(true)
                    if let first = nonNull.first {
                        object["type"] = .string(first)
                    } else {
                        object["type"] = .string("string")
                    }
                }
            default:
                break
            }
        }

        if let anyOf = object["anyOf"] ?? object["oneOf"] ?? object["allOf"] {
            if let enumValues = collapseUnionToEnum(anyOf) {
                object.removeValue(forKey: "anyOf")
                object.removeValue(forKey: "oneOf")
                object.removeValue(forKey: "allOf")
                object["enum"] = .array(enumValues)
                collector.emit(
                    fieldPath: fieldPath,
                    code: "union.collapsedToEnum",
                    message: "Collapsed constant union to enum for strict OpenAI schema.",
                    severity: .warning
                )
            } else {
                collector.emit(
                    fieldPath: fieldPath,
                    code: "union.unsupported",
                    message: "anyOf/oneOf/allOf unsupported in strict OpenAI schema.",
                    severity: .error
                )
                return node
            }
        }

        if isObjectType(object) {
            object["additionalProperties"] = .boolean(false)
            if case .object(let properties) = object["properties"] ?? .object([:]) {
                var transformedProperties: [String: JSON] = [:]
                for (key, value) in properties {
                    let childPath = "\(fieldPath).properties.\(key)"
                    transformedProperties[key] = transformOpenAIStrict(
                        value,
                        fieldPath: childPath,
                        collector: &collector
                    )
                }
                object["properties"] = .object(transformedProperties)
                object["required"] = .array(transformedProperties.keys.sorted().map(JSON.string))
            } else {
                object["properties"] = .object([:])
                object["required"] = .array([])
            }
        }

        if let itemsNode = object["items"] {
            object["items"] = transformOpenAIStrict(
                itemsNode,
                fieldPath: "\(fieldPath).items",
                collector: &collector
            )
        }

        return .object(object)
    }

    private static func transformGrammarConstrained(
        _ node: JSON,
        fieldPath: String,
        collector: inout TransformCollector
    ) -> JSON {
        if case .string(let stringValue) = node,
           let data = stringValue.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSON.self, from: data),
           case .object = parsed {
            collector.emit(
                fieldPath: fieldPath,
                code: "malformed.stringNode",
                message: "Schema node was a JSON string; parsed to object.",
                severity: .warning
            )
            return transformGrammarConstrained(parsed, fieldPath: fieldPath, collector: &collector)
        }

        guard case .object(var object) = node else {
            return node
        }

        if isObjectType(object), object["properties"] == nil {
            object["properties"] = .object([:])
            collector.emit(
                fieldPath: fieldPath,
                code: "malformed.bareObject",
                message: "type object without properties; filled empty properties object.",
                severity: .warning
            )
        }

        if case .object(let properties) = object["properties"] {
            var transformed: [String: JSON] = [:]
            for (key, value) in properties {
                transformed[key] = transformGrammarConstrained(
                    value,
                    fieldPath: "\(fieldPath).properties.\(key)",
                    collector: &collector
                )
            }
            object["properties"] = .object(transformed)
        }

        if let itemsNode = object["items"] {
            object["items"] = transformGrammarConstrained(
                itemsNode,
                fieldPath: "\(fieldPath).items",
                collector: &collector
            )
        }

        object = stripSchemaKeywords(from: object, keywords: grammarUnsupportedKeywords)
        return .object(object)
    }

    private static func transformGoogleStripped(
        _ node: JSON,
        fieldPath: String,
        keywordsToStrip: [String],
        collector: inout TransformCollector
    ) -> JSON {
        let _ = fieldPath
        let _ = collector
        let keywords = Set(keywordsToStrip)
        guard !keywords.isEmpty else { return node }
        guard case .object(let object) = node else { return node }
        return .object(stripSchemaKeywords(from: object, keywords: keywords))
    }

    // MARK: - Helpers

    private struct TransformCollector {
        let toolName: String
        var diagnostics: [ToolSchemaNormalizationDiagnostic] = []
        var hasBlockingError = false

        mutating func emit(
            fieldPath: String,
            code: String,
            message: String,
            severity: ToolSchemaDiagnosticSeverity
        ) {
            diagnostics.append(
                ToolSchemaNormalizationDiagnostic(
                    toolName: toolName,
                    fieldPath: fieldPath,
                    code: code,
                    message: message,
                    severity: severity
                )
            )
            if severity == .error {
                hasBlockingError = true
            }
        }
    }

    private static func deepCopy(_ json: JSON) -> JSON {
        guard let data = try? JSONEncoder().encode(json),
              let copy = try? JSONDecoder().decode(JSON.self, from: data) else {
            return json
        }
        return copy
    }

    private static func isObjectType(_ object: [String: JSON]) -> Bool {
        guard case .string(let type) = object["type"] else { return false }
        return type == "object"
    }

    private static func collapseUnionToEnum(_ union: JSON) -> [JSON]? {
        guard case .array(let branches) = union, !branches.isEmpty else { return nil }
        var values: [JSON] = []
        for branch in branches {
            guard case .object(let object) = branch else { return nil }
            if let const = object["const"] {
                values.append(const)
            } else if case .array(let enumValues) = object["enum"], enumValues.count == 1 {
                values.append(enumValues[0])
            } else {
                return nil
            }
        }
        return values
    }

    private static func stripSchemaKeywords(
        from object: [String: JSON],
        keywords: Set<String>
    ) -> [String: JSON] {
        var output = object
        for keyword in keywords {
            output.removeValue(forKey: keyword)
        }
        if case .object(let properties) = output["properties"] {
            var transformed: [String: JSON] = [:]
            for (key, value) in properties {
                if case .object(let child) = value {
                    transformed[key] = .object(stripSchemaKeywords(from: child, keywords: keywords))
                } else {
                    transformed[key] = value
                }
            }
            output["properties"] = .object(transformed)
        }
        if case .object(let items) = output["items"] {
            output["items"] = .object(stripSchemaKeywords(from: items, keywords: keywords))
        }
        return output
    }
}

/// Legacy flat-parameter rewrite kept for call sites that only have ``ToolDefinition`` arrays.
public enum ProviderToolSchemaNormalizer {
    public static func normalize(
        _ tools: [ToolDefinition],
        providerID: ProviderID,
        strictMode: Bool = false
    ) -> [ToolDefinition] {
        let profile: ToolSchemaCompatProfile
        if providerID == "openai", strictMode {
            profile = ToolSchemaCompatProfile(toolSchemaMode: .openAIStrict)
        } else if providerID == "ollama" || providerID == "lmstudio" {
            profile = ToolSchemaCompatProfile(toolSchemaMode: .grammarConstrained)
        } else {
            profile = ToolSchemaCompatProfile(toolSchemaMode: .permissive)
        }
        let entries = tools.map { tool in
            ToolRegistryEntry(
                definition: tool,
                source: .local,
                effectClass: .unknown,
                parallelHint: .unknown
            )
        }
        return ProviderToolSchemaTransform.normalize(entries: entries, profile: profile).tools
    }
}
