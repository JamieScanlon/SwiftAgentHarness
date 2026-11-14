import Foundation
import SwiftAgentKit

/// How assistant text is treated when the model's context holds wrapped external content.
public struct UntrustedLinkPolicy: Sendable, Equatable {
    /// When false, assistant text is never rewritten.
    public var enabled: Bool
    /// Hosts (and their subdomains) whose images load and whose links are never flagged.
    public var trustedHosts: Set<String>

    public static let `default` = UntrustedLinkPolicy(enabled: true, trustedHosts: [])

    public init(enabled: Bool = true, trustedHosts: Set<String> = []) {
        self.enabled = enabled
        self.trustedHosts = Set(trustedHosts.map { $0.lowercased() }.filter { !$0.isEmpty })
    }
}

/// Rewrites assistant markdown so that displaying it cannot send data to a third party: remote images are not
/// loaded, and links, autolinks, bare URLs, and reference definitions whose URL carries data are shown as inert
/// code. Code spans and fenced code blocks pass through untouched.
///
/// Feed streamed text with ``feed(_:)`` and finish with ``flush()``. Text that could still become a link or image
/// is held back until it resolves, so a chunk boundary never changes the result: the concatenated stream output
/// always equals ``sanitize(_:trustedHosts:)`` of the whole text.
struct UntrustedLinkSanitizer: Sendable {
    private struct Fence: Sendable {
        var marker: Character
        var count: Int
    }

    private enum Step {
        case needMore
        case emit(String, next: Int)
    }

    private enum Match {
        case needMore
        case noMatch
        case emit(String, next: Int)
    }

    private let trustedHosts: Set<String>
    private var pending: [Character] = []
    private var lastEmitted: Character?
    /// Spaces since the last newline while the line holds nothing else; `nil` once it does.
    private var lineIndent: Int?
    private var fence: Fence?

    init(trustedHosts: Set<String> = []) {
        self.init(trustedHosts: trustedHosts, atLineStart: true)
    }

    private init(trustedHosts: Set<String>, atLineStart: Bool) {
        self.trustedHosts = Set(trustedHosts.map { $0.lowercased() })
        self.lineIndent = atLineStart ? 0 : nil
        self.lastEmitted = atLineStart ? nil : " "
    }

    static func sanitize(_ text: String, trustedHosts: Set<String> = []) -> String {
        var sanitizer = UntrustedLinkSanitizer(trustedHosts: trustedHosts)
        return sanitizer.feed(text) + sanitizer.flush()
    }

    /// Sanitizes the message text and its text content blocks.
    static func sanitize(_ envelope: HarnessMessageEnvelope, trustedHosts: Set<String> = []) -> HarnessMessageEnvelope {
        var out = envelope
        out.message.content = sanitize(envelope.message.content, trustedHosts: trustedHosts)
        out.contentBlocks = envelope.contentBlocks.map { block in
            guard case .text(let text) = block else { return block }
            return .text(sanitize(text, trustedHosts: trustedHosts))
        }
        return out
    }

    /// True when any message holds content wrapped by the external-content envelope.
    static func containsExternalContent(_ messages: [Message]) -> Bool {
        messages.contains { ExternalContentEnvelope.isAlreadyWrapped($0.content) }
    }

    /// Returns the text that is safe to emit now; anything that could still become a link or image is held.
    mutating func feed(_ text: String) -> String {
        pending.append(contentsOf: text)
        return drain(final: false)
    }

    /// Emits everything still held; unfinished constructs are emitted as literal text.
    mutating func flush() -> String {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> String {
        let chars = pending
        var out = ""
        var index = 0
        while index < chars.count {
            switch step(chars, at: index, final: final) {
            case .needMore:
                pending = Array(chars[index...])
                return out
            case .emit(let text, let next):
                out += text
                note(text)
                index = next
            }
        }
        pending = []
        return out
    }

    private mutating func note(_ text: String) {
        for character in text {
            if character == "\n" {
                lineIndent = 0
            } else if character == " ", let indent = lineIndent {
                lineIndent = indent + 1
            } else {
                lineIndent = nil
            }
            lastEmitted = character
        }
    }

    private var atLineStart: Bool {
        lineIndent.map { $0 <= 3 } ?? false
    }

    // MARK: - Scanner

    private mutating func step(_ c: [Character], at i: Int, final: Bool) -> Step {
        let ch = c[i]
        if let open = fence {
            if atLineStart, ch == open.marker {
                let run = runLength(c, from: i, of: ch)
                if i + run == c.count, !final { return .needMore }
                if run >= open.count {
                    fence = nil
                    return .emit(String(c[i..<(i + run)]), next: i + run)
                }
            }
            if atLineStart, ch == " " { return .emit(" ", next: i + 1) }
            var end = i
            while end < c.count, c[end] != "\n" { end += 1 }
            if end < c.count { end += 1 }
            return .emit(String(c[i..<end]), next: end)
        }

        if atLineStart, ch == "`" || ch == "~" {
            let run = runLength(c, from: i, of: ch)
            if i + run == c.count, !final { return .needMore }
            if run >= 3 {
                fence = Fence(marker: ch, count: run)
                return .emit(String(c[i..<(i + run)]), next: i + run)
            }
        }

        switch ch {
        case "\\":
            if i + 1 >= c.count { return final ? .emit("\\", next: i + 1) : .needMore }
            return .emit(String(c[i...(i + 1)]), next: i + 2)
        case "`":
            return resolve(codeSpan(c, at: i, final: final), literal: c, at: i, length: runLength(c, from: i, of: "`"))
        case "!":
            if i + 1 >= c.count { return final ? .emit("!", next: i + 1) : .needMore }
            guard c[i + 1] == "[" else { return .emit("!", next: i + 1) }
            return resolve(bracket(c, open: i + 1, image: true, final: final), literal: c, at: i, length: 1)
        case "[":
            return resolve(bracket(c, open: i, image: false, final: final), literal: c, at: i, length: 1)
        case "<":
            return resolve(angle(c, at: i, final: final), literal: c, at: i, length: 1)
        case "h", "H", "w", "W":
            guard isWordBoundary else { return .emit(String(ch), next: i + 1) }
            return resolve(bareURL(c, at: i, final: final), literal: c, at: i, length: 1)
        default:
            return .emit(String(ch), next: i + 1)
        }
    }

    private func resolve(_ match: Match, literal c: [Character], at i: Int, length: Int) -> Step {
        switch match {
        case .needMore: return .needMore
        case .noMatch: return .emit(String(c[i..<(i + length)]), next: i + length)
        case .emit(let text, let next): return .emit(text, next: next)
        }
    }

    private var isWordBoundary: Bool {
        guard let previous = lastEmitted else { return true }
        if previous.isLetter || previous.isNumber { return false }
        return !"/.:@-_".contains(previous)
    }

    private func runLength(_ c: [Character], from i: Int, of character: Character) -> Int {
        var end = i
        while end < c.count, c[end] == character { end += 1 }
        return end - i
    }

    private func isBlankLine(_ c: [Character], at j: Int) -> Bool {
        c[j] == "\n" && j + 1 < c.count && c[j + 1] == "\n"
    }

    private func codeSpan(_ c: [Character], at i: Int, final: Bool) -> Match {
        let run = runLength(c, from: i, of: "`")
        var j = i + run
        while j < c.count {
            if isBlankLine(c, at: j) { return .noMatch }
            if c[j] == "`" {
                let closing = runLength(c, from: j, of: "`")
                if closing == run, j + closing < c.count || final {
                    return .emit(String(c[i..<(j + closing)]), next: j + closing)
                }
                if closing == run { return .needMore }
                j += closing
                continue
            }
            j += 1
        }
        return final ? .noMatch : .needMore
    }

    /// `[text](dest)`, `![alt](dest)`, or a `[label]: dest` reference definition at the start of a line.
    private func bracket(_ c: [Character], open o: Int, image: Bool, final: Bool) -> Match {
        let incomplete: Match = final ? .noMatch : .needMore
        var depth = 0
        var j = o
        while true {
            guard j < c.count else { return incomplete }
            let x = c[j]
            if x == "\\" {
                j += 2
                continue
            }
            if isBlankLine(c, at: j) { return .noMatch }
            if x == "[" {
                depth += 1
            } else if x == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            j += 1
        }
        let close = j
        let text = String(c[(o + 1)..<close])
        let start = image ? o - 1 : o
        let after = close + 1
        guard after < c.count else { return incomplete }

        if c[after] == "(" {
            var parens = 0
            var m = after
            while true {
                guard m < c.count else { return incomplete }
                let x = c[m]
                if x == "\\" {
                    m += 2
                    continue
                }
                if isBlankLine(c, at: m) { return .noMatch }
                if x == "(" {
                    parens += 1
                } else if x == ")" {
                    parens -= 1
                    if parens == 0 { break }
                }
                m += 1
            }
            let inner = String(c[(after + 1)..<m])
            let next = m + 1
            let destination = Self.destination(of: inner)
            let label = Self.sanitize(text, trustedHosts: trustedHosts, midLine: true)
            if image {
                if let url = Self.remoteURL(destination), !isTrusted(url.host) {
                    let notice = "(image from \(url.host) not loaded)"
                    let alt = label.trimmingCharacters(in: .whitespaces)
                    return .emit(alt.isEmpty ? notice : "\(alt) \(notice)", next: next)
                }
                return .emit("![\(label)](\(inner))", next: next)
            }
            if let url = Self.remoteURL(destination), url.carriesData, !isTrusted(url.host) {
                return .emit("\(label) \(Self.unverified(destination))", next: next)
            }
            return .emit("[\(label)](\(inner))", next: next)
        }

        if c[after] == ":", !image, atLineStart {
            var m = after + 1
            while m < c.count, c[m] != "\n" { m += 1 }
            if m >= c.count, !final { return .needMore }
            var rest = String(c[(after + 1)..<m]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty, m < c.count {
                // The destination may sit on the following line.
                var n = m + 1
                while n < c.count, c[n] != "\n" { n += 1 }
                if n >= c.count, !final { return .needMore }
                rest = String(c[(m + 1)..<n]).trimmingCharacters(in: .whitespaces)
                m = n
            }
            let destination = Self.destination(of: rest)
            guard Self.remoteURL(destination).map({ !isTrusted($0.host) }) == true else {
                return .emit(String(c[start..<m]), next: m)
            }
            return .emit("\(text): \(Self.unverified(destination))", next: m)
        }
        return .noMatch
    }

    /// `<img …>` tags and `<scheme://…>` autolinks.
    private func angle(_ c: [Character], at a: Int, final: Bool) -> Match {
        let incomplete: Match = final ? .noMatch : .needMore
        let lookahead = String(c[(a + 1)..<min(c.count, a + 9)]).lowercased()
        let reachedEnd = a + 9 > c.count

        if lookahead.hasPrefix("img"), lookahead.count > 3 {
            let next = lookahead[lookahead.index(lookahead.startIndex, offsetBy: 3)]
            guard next.isWhitespace || next == "/" || next == ">" else { return .noMatch }
            var j = a + 1
            while true {
                guard j < c.count else { return incomplete }
                if isBlankLine(c, at: j) { return .noMatch }
                if c[j] == ">" { break }
                j += 1
            }
            let tag = String(c[a...j])
            if let source = Self.imageSource(in: tag), let url = Self.remoteURL(source), !isTrusted(url.host) {
                return .emit("(image from \(url.host) not loaded)", next: j + 1)
            }
            return .emit(tag, next: j + 1)
        }

        if lookahead.hasPrefix("http://") || lookahead.hasPrefix("https://") {
            var j = a + 1
            while true {
                guard j < c.count else { return incomplete }
                let x = c[j]
                if x == ">" { break }
                if x.isWhitespace || x == "<" { return .noMatch }
                j += 1
            }
            let destination = String(c[(a + 1)..<j])
            if let url = Self.remoteURL(destination), url.carriesData, !isTrusted(url.host) {
                return .emit(Self.unverified(destination), next: j + 1)
            }
            return .emit(String(c[a...j]), next: j + 1)
        }

        if reachedEnd, !final, ["img", "http://", "https://"].contains(where: { $0.hasPrefix(lookahead) }) {
            return .needMore
        }
        return .noMatch
    }

    /// GFM autolinked text: `http://…`, `https://…`, and `www.…`.
    private func bareURL(_ c: [Character], at b: Int, final: Bool) -> Match {
        let prefixes = ["http://", "https://", "www."]
        let lookahead = String(c[b..<min(c.count, b + 8)]).lowercased()
        guard prefixes.contains(where: { lookahead.hasPrefix($0) }) else {
            let mayStillMatch = b + 8 > c.count && prefixes.contains(where: { $0.hasPrefix(lookahead) })
            return mayStillMatch && !final ? .needMore : .noMatch
        }
        var j = b
        while j < c.count, !c[j].isWhitespace, !"<>`".contains(c[j]) { j += 1 }
        if j == c.count, !final { return .needMore }
        var url = Array(c[b..<j])
        var trailing: [Character] = []
        while let last = url.last {
            let unbalancedParen = last == ")" && url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count
            guard ".,:;!?*_~'\"".contains(last) || unbalancedParen else { break }
            trailing.insert(url.removeLast(), at: 0)
        }
        let destination = String(url)
        if let remote = Self.remoteURL(destination), remote.carriesData, !isTrusted(remote.host) {
            return .emit(Self.unverified(destination) + String(trailing), next: j)
        }
        return .emit(String(c[b..<j]), next: j)
    }

    // MARK: - URLs

    private struct RemoteURL {
        var host: String
        var carriesData: Bool
    }

    private static func sanitize(_ text: String, trustedHosts: Set<String>, midLine: Bool) -> String {
        var sanitizer = UntrustedLinkSanitizer(trustedHosts: trustedHosts, atLineStart: !midLine)
        return sanitizer.feed(text) + sanitizer.flush()
    }

    private static func unverified(_ destination: String) -> String {
        "(unverified link: `\(destination.replacingOccurrences(of: "`", with: ""))`)"
    }

    private func isTrusted(_ host: String) -> Bool {
        trustedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The destination of a link's parenthesized part: `<…>` or the first whitespace-free token.
    private static func destination(of inner: String) -> String {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        return String(trimmed.prefix { !$0.isWhitespace })
    }

    private static func imageSource(in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bsrc\s*=\s*["']?([^"'\s>]+)"#),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range])
    }

    /// Host and data signals for an `http(s)://`, protocol-relative, or `www.` URL; `nil` for anything local.
    private static func remoteURL(_ raw: String) -> RemoteURL? {
        var url = raw.trimmingCharacters(in: .whitespaces)
        let lower = url.lowercased()
        if lower.hasPrefix("//") {
            url = "http:" + url
        } else if lower.hasPrefix("www.") {
            url = "http://" + url
        } else if !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) {
            return nil
        }
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let afterScheme = url[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex { "/?#\\".contains($0) } ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        let rest = afterScheme[authorityEnd...]

        var hostPart = Substring(authority)
        let hasUserInfo = authority.contains("@")
        if let at = authority.lastIndex(of: "@") {
            hostPart = authority[authority.index(after: at)...]
        }
        if let colon = hostPart.lastIndex(of: ":"), !hostPart.hasPrefix("[") {
            hostPart = hostPart[..<colon]
        }
        let host = hostPart.lowercased()
        guard !host.isEmpty else { return nil }

        let pathEnd = rest.firstIndex { $0 == "?" || $0 == "#" } ?? rest.endIndex
        let path = rest[..<pathEnd]
        let suffix = rest[pathEnd...]
        let hasQueryOrFragment = suffix.count > 1
        let longPathSegment = path.split(separator: "/").contains { $0.count >= 40 }
        let longHostLabel = host.split(separator: ".").contains { $0.count >= 32 }
        return RemoteURL(
            host: host,
            carriesData: hasUserInfo || hasQueryOrFragment || longPathSegment || longHostLabel
        )
    }
}
