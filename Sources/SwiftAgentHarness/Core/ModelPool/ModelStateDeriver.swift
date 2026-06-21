import Foundation

/// Pure helpers for the pool-derived ``thinking`` UI signal.
enum ModelStateDeriver: Sendable {

    static let connectingThinkingThresholdSeconds: TimeInterval = 0.2

    /// True when assistant-visible content (outside reasoning markup) is empty but reasoning markup has body.
    static func streamingThinkingOnly(assistantContent: String) -> Bool {
        let visible = visibleAssistantContent(from: assistantContent)
        guard visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return reasoningTaggedContentLength(assistantContent) > 0
    }

    /// Strips common reasoning / thinking blocks for visible-text detection.
    static func visibleAssistantContent(from raw: String) -> String {
        var s = raw
        s = Self.removingXMLStyleTags(s, tag: "think")
        s = Self.removingXMLStyleTags(s, tag: "redacted_thinking")
        return s
    }

    private static func reasoningTaggedContentLength(_ raw: String) -> Int {
        func innerLength(tag: String) -> Int {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            guard let r = raw.range(of: open),
                  let end = raw.range(of: close, range: r.upperBound..<raw.endIndex)
            else { return 0 }
            return raw[r.upperBound..<end.lowerBound].count
        }
        return innerLength(tag: "think") + innerLength(tag: "redacted_thinking")
    }

    private static func removingXMLStyleTags(_ raw: String, tag: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var result = raw
        while let start = result.range(of: open),
              let end = result.range(of: close, range: start.upperBound..<result.endIndex)
        {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    static func thinking(
        phase: ModelInvocationPhase,
        connectingEnteredAt: Date?,
        now: Date,
        streamingAssistantContent: String?,
        streamingReasoningOnly: Bool = false
    ) -> Bool {
        if phase == .connecting,
           let entered = connectingEnteredAt,
           now.timeIntervalSince(entered) > connectingThinkingThresholdSeconds
        {
            return true
        }
        if phase == .streaming {
            if streamingReasoningOnly {
                return true
            }
            if let content = streamingAssistantContent,
               streamingThinkingOnly(assistantContent: content)
            {
                return true
            }
        }
        return false
    }
}
