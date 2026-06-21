//
//  Read helpers for per-agent `auth-profiles.json` (Gap 13 / README `auth_profile`).
//

import Foundation

enum SessionAuthProfilesFile {
    /// Returns payload for `name` from raw file bytes.
    ///
    /// Requires non-empty `name` (after trim). Root must be a JSON object keyed by profile name;
    /// returns UTF-8 JSON encoding of the value for that key, or `nil` if name is empty, missing, or invalid JSON.
    static func dataForProfile(from raw: Data, name: String) -> Data? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return nil
        }
        guard let value = obj[trimmed] else { return nil }
        return jsonUTF8Data(forProfileValue: value)
    }

    /// Encode a JSON value extracted from `jsonObject` (profile entry).
    private static func jsonUTF8Data(forProfileValue value: Any) -> Data? {
        switch value {
        case let d as [String: Any]:
            guard JSONSerialization.isValidJSONObject(d) else { return nil }
            return try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
        case let a as [Any]:
            guard JSONSerialization.isValidJSONObject(a) else { return nil }
            return try? JSONSerialization.data(withJSONObject: a, options: [])
        case is NSNull:
            return Data("null".utf8)
        case let b as Bool:
            return try? JSONEncoder().encode(b)
        case let s as String:
            return try? JSONEncoder().encode(s)
        case let i as Int:
            return try? JSONEncoder().encode(i)
        case let i as Int8:
            return try? JSONEncoder().encode(i)
        case let i as Int16:
            return try? JSONEncoder().encode(i)
        case let i as Int32:
            return try? JSONEncoder().encode(i)
        case let i as Int64:
            return try? JSONEncoder().encode(i)
        case let u as UInt:
            return try? JSONEncoder().encode(u)
        case let u as UInt64:
            return try? JSONEncoder().encode(u)
        case let dbl as Double:
            return try? JSONEncoder().encode(dbl)
        case let f as Float:
            return try? JSONEncoder().encode(f)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return try? JSONEncoder().encode(n.boolValue)
            }
            let d = n.doubleValue
            if d.rounded() == d, d >= Double(Int.min), d <= Double(Int.max) {
                return try? JSONEncoder().encode(n.intValue)
            }
            return try? JSONEncoder().encode(d)
        default:
            return nil
        }
    }

    static func loadProfile(fromFileAt url: URL, name: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try Data(contentsOf: url)
        return dataForProfile(from: raw, name: name)
    }
}
