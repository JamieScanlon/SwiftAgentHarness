import Foundation
import SwiftAgentKit

extension Message {
    /// Parsed key-value metadata from the trigger line, or `nil` if this message is not a trigger message (content does not start with `[trigger]`).
    /// Use for UI (e.g. "From: X, type: Y") and for trust/auth logic.
    var triggerMetadata: [String: String]? {
        TriggerContentBuilder.parse(content: content).triggerMetadata
    }

    /// The message body: text after `\n\n` when content starts with `[trigger]`, otherwise the full content.
    /// Use when you need only the user-facing body for display or logic.
    var messageBodyContent: String {
        TriggerContentBuilder.parse(content: content).messageBody
    }
}

extension CachedMessage {
    /// Parsed key-value metadata from the trigger line, or `nil` if this message is not a trigger message (content does not start with `[trigger]`).
    var triggerMetadata: [String: String]? {
        TriggerContentBuilder.parse(content: content).triggerMetadata
    }

    /// The message body: text after `\n\n` when content starts with `[trigger]`, otherwise the full content.
    var messageBodyContent: String {
        TriggerContentBuilder.parse(content: content).messageBody
    }
}
