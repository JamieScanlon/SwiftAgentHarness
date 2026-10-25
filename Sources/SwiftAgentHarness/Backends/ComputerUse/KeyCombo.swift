import Foundation

public enum KeyModifier: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case ctrl
    case option
    case shift
    case cmd
    case fn

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: KeyModifier, rhs: KeyModifier) -> Bool {
        lhs.order < rhs.order
    }

    static let aliases: [String: KeyModifier] = [
        "ctrl": .ctrl, "control": .ctrl,
        "option": .option, "opt": .option, "alt": .option,
        "shift": .shift,
        "cmd": .cmd, "command": .cmd, "meta": .cmd, "super": .cmd, "win": .cmd,
        "fn": .fn, "globe": .fn,
    ]
}

public enum KeyComboParseError: Error, Sendable, Equatable {
    case empty
    case missingKey(String)
    case multipleKeys(String)
}

/// A normalized key chord such as `shift+cmd+a`. Equality is by canonical form, so every spelling of the same chord
/// compares equal — the property the stop-key and system-key checks depend on.
public struct KeyCombo: Sendable, Hashable, Codable, CustomStringConvertible {
    public let modifiers: Set<KeyModifier>
    public let key: String

    static let keyAliases: [String: String] = [
        "esc": "escape",
        "enter": "return",
        "del": "delete",
        "backspace": "delete",
        "forwarddelete": "forward-delete",
        "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
        "pgup": "page-up", "pageup": "page-up", "pgdn": "page-down", "pagedown": "page-down",
    ]

    public init(modifiers: Set<KeyModifier>, key: String) {
        self.modifiers = modifiers
        let lowered = key.lowercased()
        self.key = Self.keyAliases[lowered] ?? lowered
    }

    public init(parsing raw: String) throws {
        let parts = raw.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw KeyComboParseError.empty }
        var modifiers = Set<KeyModifier>()
        var key: String?
        for part in parts {
            if let modifier = KeyModifier.aliases[part] {
                modifiers.insert(modifier)
            } else if key == nil {
                key = part
            } else {
                throw KeyComboParseError.multipleKeys(raw)
            }
        }
        guard let key else { throw KeyComboParseError.missingKey(raw) }
        self.init(modifiers: modifiers, key: key)
    }

    public var description: String {
        (modifiers.sorted().map(\.rawValue) + [key]).joined(separator: "+")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(parsing: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
