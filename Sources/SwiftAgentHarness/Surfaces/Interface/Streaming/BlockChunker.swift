import Foundation

/// Buffers model text and emits coarse blocks respecting bounds, break preferences, and code-fence safety.
public struct BlockChunker: Sendable {
    private var buffer: String = ""
    private let minChars: Int
    private let maxChars: Int
    private let maxLines: Int?
    private let breakPreference: BreakPreference

    public init(config: ChunkerConfig, breakPreference: BreakPreference = .paragraph) {
        self.minChars = max(1, config.minChars)
        self.maxChars = max(self.minChars, config.effectiveMaxChars)
        self.maxLines = config.maxLines
        self.breakPreference = breakPreference
    }

    public var pendingLength: Int { buffer.count }

    /// Appends text and returns any completed blocks ready to send.
    public mutating func ingest(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        buffer += text
        return drain(force: false)
    }

    /// Flushes all remaining buffered text (end-of-turn).
    public mutating func flush() -> [String] {
        drain(force: true)
    }

    /// Discards in-flight buffer without emitting (cancellation discard path).
    public mutating func discardPending() {
        buffer = ""
    }

    // MARK: - Drain

    private mutating func drain(force: Bool) -> [String] {
        var emitted: [String] = []
        while !buffer.isEmpty {
            if !force && buffer.count < minChars {
                break
            }
            guard let chunk = extractNextChunk(force: force) else { break }
            emitted.append(chunk)
        }
        return emitted
    }

    private mutating func extractNextChunk(force: Bool) -> String? {
        if buffer.isEmpty { return nil }

        let limit = lineAwareLimit(for: buffer)

        if force {
            if buffer.count <= limit {
                return emitAll()
            }
            let hardIndex = buffer.index(buffer.startIndex, offsetBy: limit)
            if let split = findBestBreak(in: buffer, searchUpTo: hardIndex, forced: false) {
                return emit(upTo: split)
            }
            return emitHard(at: hardIndex)
        }

        if buffer.count < minChars {
            return nil
        }

        if buffer.count <= limit {
            if let split = findBestBreak(in: buffer, searchUpTo: buffer.endIndex, forced: false) {
                return emit(upTo: split)
            }
            return nil
        }

        let hardIndex = buffer.index(buffer.startIndex, offsetBy: limit)
        if let split = findBestBreak(in: buffer, searchUpTo: hardIndex, forced: false) {
            return emit(upTo: split)
        }
        return emitHard(at: hardIndex)
    }

    private func lineAwareLimit(for text: String) -> Int {
        guard let maxLines else { return maxChars }
        var charCount = 0
        var lineCount = 0
        for (index, char) in text.enumerated() {
            if index >= maxChars { break }
            if char == "\n" {
                lineCount += 1
                if lineCount >= maxLines {
                    return max(minChars, index + 1)
                }
            }
            charCount = index + 1
        }
        return min(maxChars, max(minChars, charCount))
    }

    private mutating func emit(upTo splitIndex: String.Index) -> String {
        let chunk = String(buffer[..<splitIndex])
        buffer = String(buffer[splitIndex...]).trimmingLeadingWhitespace()
        return chunk
    }

    private mutating func emitAll() -> String {
        let chunk = buffer
        buffer = ""
        return chunk
    }

    private mutating func emitHard(at index: String.Index) -> String {
        var chunk = String(buffer[..<index])
        var remainder = String(buffer[index...])

        if let fence = activeFence(at: index, in: buffer) {
            chunk += "\n```"
            let reopen = fence.language.map { "```\($0)\n" } ?? "```\n"
            remainder = reopen + remainder
        }

        buffer = remainder
        return chunk
    }

    // MARK: - Break search

    private func findBestBreak(in text: String, searchUpTo: String.Index, forced: Bool) -> String.Index? {
        let fences = CodeFenceParser.spans(in: text)
        let minIndex = text.index(
            text.startIndex,
            offsetBy: min(minChars, text.count),
            limitedBy: text.endIndex
        ) ?? text.endIndex

        let candidates = breakCandidates(in: text, upTo: searchUpTo)
        for candidate in candidates {
            guard candidate >= minIndex else { continue }
            guard candidate <= searchUpTo else { continue }
            if !CodeFenceParser.isInsideFence(candidate, spans: fences) {
                return candidate
            }
        }

        if forced {
            return searchUpTo
        }
        return nil
    }

    private func breakCandidates(in text: String, upTo searchEnd: String.Index) -> [String.Index] {
        var results: [String.Index] = []
        let preferences: [BreakPreference]
        switch breakPreference {
        case .paragraph:
            preferences = [.paragraph, .newline, .sentence, .whitespace, .hard]
        case .newline:
            preferences = [.newline, .sentence, .whitespace, .hard]
        case .sentence:
            preferences = [.sentence, .whitespace, .hard]
        case .whitespace:
            preferences = [.whitespace, .hard]
        case .hard:
            preferences = [.hard]
        }

        for preference in preferences {
            results.append(contentsOf: candidates(for: preference, in: text, upTo: searchEnd))
        }

        return Array(Set(results.map { $0 })).sorted(by: >)
    }

    private func candidates(for preference: BreakPreference, in text: String, upTo searchEnd: String.Index) -> [String.Index] {
        var results: [String.Index] = []
        let searchRange = text.startIndex..<searchEnd

        func appendIfValid(_ index: String.Index) {
            if index > text.startIndex, index <= searchEnd {
                results.append(index)
            }
        }

        switch preference {
        case .paragraph:
            var start = searchRange.lowerBound
            while start < searchEnd {
                if let range = text.range(of: "\n\n", range: start..<searchEnd) {
                    appendIfValid(range.upperBound)
                    start = range.upperBound
                } else {
                    break
                }
            }
        case .newline:
            var start = searchRange.lowerBound
            while start < searchEnd {
                if let range = text.range(of: "\n", range: start..<searchEnd) {
                    appendIfValid(range.upperBound)
                    start = range.upperBound
                } else {
                    break
                }
            }
        case .sentence:
            var index = text.startIndex
            while index < searchEnd {
                let char = text[index]
                if ".!?".contains(char) {
                    let next = text.index(after: index)
                    if next >= searchEnd || text[next].isWhitespace {
                        appendIfValid(next <= searchEnd ? next : searchEnd)
                    }
                }
                index = text.index(after: index)
            }
        case .whitespace:
            var start = searchRange.lowerBound
            while start < searchEnd {
                if let range = text.rangeOfCharacter(from: .whitespaces, range: start..<searchEnd) {
                    appendIfValid(range.upperBound)
                    start = range.upperBound
                } else {
                    break
                }
            }
        case .hard:
            appendIfValid(searchEnd)
        }
        return results
    }

    private func activeFence(at index: String.Index, in text: String) -> CodeFenceSpan? {
        let spans = CodeFenceParser.spans(in: text)
        for span in spans {
            let contentStart = span.contentStart(in: text)
            let contentEnd = span.closeStart ?? text.endIndex
            if index > contentStart && index < contentEnd {
                return span
            }
        }
        return nil
    }
}

// MARK: - Code fence parsing

struct CodeFenceSpan: Sendable, Equatable {
    let openStart: String.Index
    let openLineEnd: String.Index
    let closeStart: String.Index?
    let language: String?

    func contentStart(in text: String) -> String.Index {
        if openLineEnd < text.endIndex, text[openLineEnd] == "\n" {
            return text.index(after: openLineEnd)
        }
        return openLineEnd
    }
}

enum CodeFenceParser {
    static func spans(in text: String) -> [CodeFenceSpan] {
        var spans: [CodeFenceSpan] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            guard let openRange = text.range(of: "```", range: searchStart..<text.endIndex) else { break }

            let lineEnd = text[openRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let langStart = openRange.upperBound
            let language: String?
            if langStart < lineEnd {
                let lang = text[langStart..<lineEnd].trimmingCharacters(in: .whitespaces)
                language = lang.isEmpty ? nil : String(lang)
            } else {
                language = nil
            }

            let afterOpen = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            if let closeRange = text.range(of: "\n```", range: afterOpen..<text.endIndex) {
                spans.append(CodeFenceSpan(
                    openStart: openRange.lowerBound,
                    openLineEnd: lineEnd,
                    closeStart: closeRange.lowerBound,
                    language: language
                ))
                searchStart = closeRange.upperBound
            } else if afterOpen < text.endIndex,
                      let closeRange = text.range(of: "```", range: afterOpen..<text.endIndex) {
                spans.append(CodeFenceSpan(
                    openStart: openRange.lowerBound,
                    openLineEnd: lineEnd,
                    closeStart: closeRange.lowerBound,
                    language: language
                ))
                searchStart = closeRange.upperBound
            } else {
                spans.append(CodeFenceSpan(
                    openStart: openRange.lowerBound,
                    openLineEnd: lineEnd,
                    closeStart: nil,
                    language: language
                ))
                break
            }
        }
        return spans
    }

    static func isInsideFence(_ index: String.Index, spans: [CodeFenceSpan]) -> Bool {
        for span in spans {
            if index <= span.openStart { continue }
            if span.closeStart == nil {
                return true
            }
            if index < span.closeStart! {
                return true
            }
        }
        return false
    }
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        guard let firstNonWhitespace = firstIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        return String(self[firstNonWhitespace...])
    }
}
