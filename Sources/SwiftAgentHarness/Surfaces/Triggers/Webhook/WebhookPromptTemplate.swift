import Foundation

enum WebhookPromptTemplate {
    static let rawPlaceholder = "{__raw__}"
    private static let maxRawChars = 4000
    private static let maxNestedChars = 2000

    static func render(template: String, payload: [String: Any]) -> String {
        if template.contains(rawPlaceholder) {
            let raw = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let truncated = String(raw.prefix(maxRawChars))
            return template.replacingOccurrences(of: rawPlaceholder, with: truncated)
        }
        var result = template
        let pattern = #"\{([a-zA-Z0-9_.]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let keyRange = match.range(at: 1)
            let key = ns.substring(with: keyRange)
            let value = resolve(key: key, payload: payload)
            let fullRange = match.range(at: 0)
            result = (result as NSString).replacingCharacters(in: fullRange, with: value)
        }
        return result
    }

    private static func resolve(key: String, payload: [String: Any]) -> String {
        let parts = key.split(separator: ".").map(String.init)
        var current: Any = payload
        for part in parts {
            if let dict = current as? [String: Any], let next = dict[part] {
                current = next
            } else {
                return "{\(key)}"
            }
        }
        if let s = current as? String {
            return String(s.prefix(maxNestedChars))
        }
        if let data = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return String(s.prefix(maxNestedChars))
        }
        return "{\(key)}"
    }

    static func renderExtras(_ extras: [String: String]?, payload: [String: Any]) -> [String: String] {
        guard let extras, !extras.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: extras.map { key, template in
            (key, render(template: template, payload: payload))
        })
    }
}
