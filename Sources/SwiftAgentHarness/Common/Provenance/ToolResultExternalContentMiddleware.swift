import Foundation
import Logging
import SwiftAgentKit

enum ToolResultExternalContentMiddleware {
    static func apply(
        toolCall: ToolCall,
        result: ToolResult,
        entry: ToolRegistryEntry?,
        logger: Logger? = nil
    ) -> ToolResult {
        let content = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return result }
        guard !ExternalContentEnvelope.isAlreadyWrapped(result.content) else { return result }

        let decision = ToolExternalContentPolicy.resolve(toolName: toolCall.name, entry: entry)
        guard decision.shouldWrap else { return result }

        let wrapped = ExternalContentEnvelope.wrap(
            result.content,
            options: ExternalContentEnvelopeOptions(
                source: decision.source,
                from: decision.from,
                subject: nil,
                includeSecurityPreamble: decision.includeSecurityPreamble
            )
        )
        logger?.debug(
            "external_content_wrap tool=\(toolCall.name) source=\(decision.source.rawValue) preamble=\(decision.includeSecurityPreamble)"
        )
        return ToolResult(
            success: result.success,
            content: wrapped,
            metadata: result.metadata,
            toolCallId: result.toolCallId,
            error: result.error
        )
    }
}
