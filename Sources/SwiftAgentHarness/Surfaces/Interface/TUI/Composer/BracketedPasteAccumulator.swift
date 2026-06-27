import Foundation

/// Reassembles bracketed-paste sequences that arrive fragmented across terminal reads.
public struct BracketedPasteAccumulator: Sendable {
    private var buffer = ""
    private var inPaste = false

    public init() {}

    /// Feeds one terminal read; returns ordered chunks safe to dispatch.
    /// Each returned chunk is either normal input or a complete `start..end` paste envelope.
    public mutating func feed(_ data: String) -> [String] {
        buffer += data
        var output: [String] = []

        var madeProgress = true
        while madeProgress {
            madeProgress = false

            if inPaste {
                if let endRange = buffer.range(of: BracketedPaste.end) {
                    let pasteEnd = endRange.upperBound
                    output.append(String(buffer[..<pasteEnd]))
                    buffer = String(buffer[pasteEnd...])
                    inPaste = false
                    madeProgress = true
                    continue
                }
                break
            }

            if let startRange = buffer.range(of: BracketedPaste.start) {
                let beforeStart = String(buffer[..<startRange.lowerBound])
                if !beforeStart.isEmpty {
                    output.append(beforeStart)
                }
                buffer = String(buffer[startRange.lowerBound...])
                inPaste = true
                madeProgress = true
                continue
            }

            let hold = Self.longestSuffixThatIsPrefix(of: BracketedPaste.start, in: buffer)
            if hold > 0 {
                let emitEnd = buffer.index(buffer.endIndex, offsetBy: -hold)
                let emitChunk = String(buffer[..<emitEnd])
                if !emitChunk.isEmpty {
                    output.append(emitChunk)
                }
                buffer = String(buffer[emitEnd...])
            } else if !buffer.isEmpty {
                output.append(buffer)
                buffer = ""
            }
            break
        }

        return output
    }

    private static func longestSuffixThatIsPrefix(of marker: String, in text: String) -> Int {
        let maxK = min(marker.count - 1, text.count)
        guard maxK > 0 else { return 0 }
        for k in stride(from: maxK, through: 1, by: -1) {
            if text.suffix(k) == marker.prefix(k) {
                return k
            }
        }
        return 0
    }
}

/// `@unchecked Sendable`: state is serialized by `NSLock` (true internal thread safety).
public final class BracketedPasteAccumulatorBox: @unchecked Sendable {
    private var accumulator = BracketedPasteAccumulator()
    private let lock = NSLock()

    public init() {}

    public func feed(_ data: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.feed(data)
    }
}
