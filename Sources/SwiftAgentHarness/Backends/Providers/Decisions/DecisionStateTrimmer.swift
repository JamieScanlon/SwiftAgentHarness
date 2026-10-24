import EasyJSON
import Foundation

/// Trims a request's state for a single retry after a token-limit rejection that splitting questions cannot fix.
///
/// Only the longest string anywhere in the state is shortened (head and tail kept, the middle replaced by a visible
/// marker), so the structure and every other field survive and the model can see that content was cut.
public enum DecisionStateTrimmer {
    /// Strings shorter than this are left alone; trimming them would not meaningfully reduce the request.
    public static let minimumTrimmableCharacters = 512

    /// The state with its longest string halved, or `nil` when no string is long enough to trim.
    public static func trimmed(_ state: JSON, keepFraction: Double = 0.5) -> JSON? {
        guard let longest = longestStringLength(in: state), longest >= minimumTrimmableCharacters else { return nil }
        var done = false
        return rewrite(state, targetLength: longest, keepFraction: keepFraction, done: &done)
    }

    static func shorten(_ text: String, keepFraction: Double) -> String {
        let keep = max(1, Int(Double(text.count) * keepFraction))
        let head = keep * 2 / 3
        let tail = keep - head
        let removed = text.count - head - tail
        return String(text.prefix(head)) + "\n…[\(removed) characters trimmed]…\n" + String(text.suffix(tail))
    }

    private static func longestStringLength(in json: JSON) -> Int? {
        switch json {
        case .string(let value): return value.count
        case .array(let values): return values.compactMap(longestStringLength).max()
        case .object(let object): return object.values.compactMap(longestStringLength).max()
        default: return nil
        }
    }

    private static func rewrite(_ json: JSON, targetLength: Int, keepFraction: Double, done: inout Bool) -> JSON {
        guard !done else { return json }
        switch json {
        case .string(let value) where value.count == targetLength:
            done = true
            return .string(shorten(value, keepFraction: keepFraction))
        case .array(let values):
            return .array(values.map { rewrite($0, targetLength: targetLength, keepFraction: keepFraction, done: &done) })
        case .object(let object):
            var result: [String: JSON] = [:]
            for key in object.keys.sorted() {
                result[key] = rewrite(object[key]!, targetLength: targetLength, keepFraction: keepFraction, done: &done)
            }
            return .object(result)
        default:
            return json
        }
    }
}
