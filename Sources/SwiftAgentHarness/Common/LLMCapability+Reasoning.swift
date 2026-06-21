import Foundation
import SwiftAgentKit

public extension Collection where Element == LLMCapability {
    /// Optional “thinking” / reasoning mode the caller can toggle (excludes always-on reasoning models).
    var supportsOptionalReasoning: Bool {
        contains(.thinking)
    }

    /// Model exposes reasoning in some form (optional via `.thinking` or always-on via `.reasoningRequired`).
    var hasReasoningCapability: Bool {
        contains(.thinking) || contains(.reasoningRequired)
    }
}
