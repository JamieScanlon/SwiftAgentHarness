import CryptoKit
import Foundation

/// What the session has recorded as progress. Decided only from harness facts, never from the model's claims or
/// from screen text.
public struct ComputerUseProgress: Sendable, Codable, Hashable {
    /// Success criteria verified as met for the first time.
    public var criteriaVerified = 0
    /// States not seen before, each first observed after an acting step that wasn't a known failure.
    public var statesReached = 0
    /// The step count when progress last happened.
    public var lastProgressStep: Int?

    public init() {}
}

/// A coarse, structural digest of the screen state: the observed app, window, page, focused element's role, and the
/// shape of the tree, which is the sequence of roles in the compact tree with indentation as nesting. Text and values
/// are left out, so a ticking clock or a feed adding items mostly doesn't make a state look new. Digests are only
/// compared, never shown to a model.
public enum ComputerUseStateDigest {
    public static func of(_ observation: DisplayObservation) -> String? {
        let target = observation.target
        var parts: [String] = []
        if let app = target.app { parts.append("app=\(app.bundleID)") }
        if let window = target.windowID { parts.append("window=\(window)") }
        if let url = target.url.map(page) { parts.append("url=\(url)") }
        guard !parts.isEmpty else { return nil }
        if let tree = observation.tree {
            if let focused = tree.elements.values.filter(\.isFocused).map(\.role).min() { parts.append("focus=\(focused)") }
            parts.append("shape=" + shape(tree.text).joined(separator: ","))
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Each line's indentation and first word after its ref: `[e2] button "Bold"` indented once is `2:button`.
    static func shape(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let indent = line.prefix { $0 == " " }.count
            var rest = line.drop { $0 == " " }
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                rest = rest[rest.index(after: close)...].drop { $0 == " " }
            }
            guard let role = rest.split(separator: " ", maxSplits: 1).first else { return nil }
            return "\(indent):\(role)"
        }
    }

    /// The URL without its fragment, which names a place on the page rather than a page.
    private static func page(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.fragment = nil
        return components.string ?? url
    }
}
