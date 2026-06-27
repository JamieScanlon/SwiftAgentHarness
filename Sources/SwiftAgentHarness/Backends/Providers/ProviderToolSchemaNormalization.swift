import Foundation
import SwiftAgentKit

/// Central tool-schema rewrite seam (spec: runtime plan tools.normalize).
public enum ProviderToolSchemaNormalizer {
    public static func normalize(
        _ tools: [ToolDefinition],
        providerID: ProviderID,
        strictMode: Bool = false
    ) -> [ToolDefinition] {
        tools.map { tool in
            ToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters.map { param in
                    .init(
                        name: param.name,
                        description: param.description,
                        type: normalizeType(param.type, providerID: providerID, strictMode: strictMode),
                        required: param.required
                    )
                },
                type: tool.type
            )
        }
    }

    private static func normalizeType(_ type: String, providerID: ProviderID, strictMode: Bool) -> String {
        switch providerID {
        case "openai":
            if strictMode {
                return stripOpenAIStrictUnsupportedTypes(type)
            }
            return type
        default:
            return type
        }
    }

    private static func stripOpenAIStrictUnsupportedTypes(_ type: String) -> String {
        let lowered = type.lowercased()
        if lowered.contains("anyof") || lowered.contains("oneof") || lowered.contains("allof") {
            return "string"
        }
        return type
    }
}
