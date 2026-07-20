import Foundation
import SwiftAgentKit

struct ContextCompactionMessageSegments: Sendable {
    var head: [Message]
    var middle: [Message]
    var tail: [Message]
    var lastUserPinSkipped: Bool

    init(head: [Message], middle: [Message], tail: [Message], lastUserPinSkipped: Bool = false) {
        self.head = head
        self.middle = middle
        self.tail = tail
        self.lastUserPinSkipped = lastUserPinSkipped
    }
}

enum ContextCompactionMessageSplit: Sendable {
    /// Splits a transcript into `head`, `middle`, and `tail` regions used by context compaction.
    ///
    /// Tail sizing follows the harness spec: at least ``ContextCompactionSplitOptions/tailMinMessageCount``
    /// messages and at least ``ContextCompactionSplitOptions/tailTokenBudget`` estimated tokens
    /// (whichever requires a larger suffix). Boundary safety rules:
    /// - The latest user message after `head` is always pinned into `tail` (non-negotiable run anchor).
    /// - A `.tool` message never starts the tail; assistant tool-call batches stay intact (fail-closed on ID mismatch).
    /// - The head/middle boundary receives the same tool-pair protection.
    ///
    /// `lastUserPinSkipped` is retained for call-site compatibility and is always `false`.
    static func splitForCompaction(
        _ messages: [Message],
        options: ContextCompactionSplitOptions
    ) -> ContextCompactionMessageSegments {
        guard !messages.isEmpty else {
            return ContextCompactionMessageSegments(head: [], middle: [], tail: [], lastUserPinSkipped: false)
        }

        var headEnd = min(options.headMinMessageCount, messages.count)
        headEnd = adjustHeadEnd(messages: messages, proposedHeadEnd: headEnd)

        let tailMin = min(options.tailMinMessageCount, max(0, messages.count - headEnd))
        var tailStart = max(headEnd, messages.count - tailMin)

        let divisor = max(0.5, options.charactersPerToken)
        var tailUTF8 = messages[tailStart...].reduce(0) { $0 + $1.content.utf8.count }

        while tailStart > headEnd {
            let tokens = Int(ceil(Double(tailUTF8) / divisor))
            if tokens >= options.tailTokenBudget, messages.count - tailStart >= tailMin {
                break
            }
            tailStart -= 1
            tailUTF8 += messages[tailStart].content.utf8.count
        }

        if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }),
           lastUserIndex > headEnd {
            tailStart = min(tailStart, lastUserIndex)
        }
        tailStart = adjustTailStart(messages: messages, proposedTailStart: tailStart, headEnd: headEnd)
        guard tailStart > headEnd else {
            return ContextCompactionMessageSegments(head: messages, middle: [], tail: [], lastUserPinSkipped: false)
        }

        let head = Array(messages[..<headEnd])
        let middle = Array(messages[headEnd..<tailStart])
        guard !middle.isEmpty else {
            return ContextCompactionMessageSegments(head: messages, middle: [], tail: [], lastUserPinSkipped: false)
        }
        let tail = Array(messages[tailStart...])
        return ContextCompactionMessageSegments(
            head: head,
            middle: middle,
            tail: tail,
            lastUserPinSkipped: false
        )
    }

    static func rawMiddle(from messages: [Message], options: ContextCompactionSplitOptions) -> [Message] {
        splitForCompaction(messages, options: options).middle
    }

    private static func adjustTailStart(
        messages: [Message],
        proposedTailStart: Int,
        headEnd: Int
    ) -> Int {
        var tailStart = proposedTailStart
        while tailStart > headEnd && tailStart < messages.count && messages[tailStart].role == .tool {
            tailStart -= 1
        }
        return tailStart
    }

    private static func adjustHeadEnd(messages: [Message], proposedHeadEnd: Int) -> Int {
        var headEnd = proposedHeadEnd
        // Pair-check first: shrink head before a dangling assistant tool_use.
        // Then walk back past leading .tool messages — inverse of tail adjustment,
        // because headEnd is a lower bound index rather than an upper bound.
        while headEnd > 0 && headEnd < messages.count {
            let left = messages[headEnd - 1]
            let right = messages[headEnd]
            guard left.role == .assistant, !left.toolCalls.isEmpty, right.role == .tool else { break }
            headEnd -= 1
        }
        while headEnd > 0 && headEnd < messages.count && messages[headEnd].role == .tool {
            headEnd -= 1
        }
        return headEnd
    }
}
