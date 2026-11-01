import EasyJSON
import Foundation

/// Canonical input mapped to `Input.dispatch*` parameters.
enum CDPInput {
    struct Key: Equatable {
        var key: String
        var code: String
        var keyCode: Int
        var text: String?
    }

    static func modifierMask(_ modifiers: some Sequence<KeyModifier>) -> Int {
        modifiers.reduce(0) { mask, modifier in
            switch modifier {
            case .option: return mask | 1
            case .ctrl: return mask | 2
            case .cmd: return mask | 4
            case .shift: return mask | 8
            case .fn: return mask
            }
        }
    }

    static let named: [String: Key] = {
        var keys: [String: Key] = [
            "return": Key(key: "Enter", code: "Enter", keyCode: 13, text: "\r"),
            "tab": Key(key: "Tab", code: "Tab", keyCode: 9, text: nil),
            "escape": Key(key: "Escape", code: "Escape", keyCode: 27, text: nil),
            "delete": Key(key: "Backspace", code: "Backspace", keyCode: 8, text: nil),
            "forward-delete": Key(key: "Delete", code: "Delete", keyCode: 46, text: nil),
            "space": Key(key: " ", code: "Space", keyCode: 32, text: " "),
            "up": Key(key: "ArrowUp", code: "ArrowUp", keyCode: 38, text: nil),
            "down": Key(key: "ArrowDown", code: "ArrowDown", keyCode: 40, text: nil),
            "left": Key(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37, text: nil),
            "right": Key(key: "ArrowRight", code: "ArrowRight", keyCode: 39, text: nil),
            "home": Key(key: "Home", code: "Home", keyCode: 36, text: nil),
            "end": Key(key: "End", code: "End", keyCode: 35, text: nil),
            "page-up": Key(key: "PageUp", code: "PageUp", keyCode: 33, text: nil),
            "page-down": Key(key: "PageDown", code: "PageDown", keyCode: 34, text: nil),
            "insert": Key(key: "Insert", code: "Insert", keyCode: 45, text: nil),
        ]
        for number in 1...12 {
            keys["f\(number)"] = Key(key: "F\(number)", code: "F\(number)", keyCode: 111 + number, text: nil)
        }
        let punctuation: [(Character, String, Int)] = [
            ("-", "Minus", 189), ("=", "Equal", 187), ("[", "BracketLeft", 219), ("]", "BracketRight", 221),
            ("\\", "Backslash", 220), (";", "Semicolon", 186), ("'", "Quote", 222), (",", "Comma", 188),
            (".", "Period", 190), ("/", "Slash", 191), ("`", "Backquote", 192),
        ]
        for (character, code, keyCode) in punctuation {
            keys[String(character)] = Key(key: String(character), code: code, keyCode: keyCode, text: String(character))
        }
        return keys
    }()

    /// The key for a combo's key name, or `nil` when it names no key.
    static func key(_ name: String, shifted: Bool) -> Key? {
        if let key = named[name] { return key }
        guard name.count == 1, let character = name.first else { return nil }
        if character.isLetter, character.isASCII {
            let upper = character.uppercased()
            let text = shifted ? upper : character.lowercased()
            return Key(key: text, code: "Key\(upper)", keyCode: Int(upper.unicodeScalars.first!.value), text: text)
        }
        if character.isNumber, character.isASCII {
            return Key(key: name, code: "Digit\(name)", keyCode: Int(character.unicodeScalars.first!.value), text: name)
        }
        return Key(key: name, code: "", keyCode: 0, text: name)
    }

    /// Editing commands a macOS Chromium only runs when the key event names them. Clipboard commands are left out,
    /// so the agent never reads or writes the host's clipboard through the browser.
    static func commands(for combo: KeyCombo) -> [String] {
        guard combo.modifiers.contains(.cmd), !combo.modifiers.contains(.ctrl), !combo.modifiers.contains(.option) else { return [] }
        switch (combo.key, combo.modifiers.contains(.shift)) {
        case ("a", false): return ["selectAll"]
        case ("z", false): return ["undo"]
        case ("z", true): return ["redo"]
        default: return []
        }
    }

    /// The down and up events for one press of `combo`; `nil` when it names no key.
    static func keyEvents(_ combo: KeyCombo) -> (down: [String: JSON], up: [String: JSON])? {
        let shifted = combo.modifiers.contains(.shift)
        guard let key = key(combo.key, shifted: shifted) else { return nil }
        let mask = modifierMask(combo.modifiers)
        // Text only goes with an unmodified (or shifted) press; a chord is a shortcut, not typing.
        let text = combo.modifiers.isSubset(of: [.shift]) ? key.text : nil
        var down: [String: JSON] = [
            "type": .string(text == nil ? "rawKeyDown" : "keyDown"),
            "modifiers": .integer(mask),
            "key": .string(key.key),
            "code": .string(key.code),
            "windowsVirtualKeyCode": .integer(key.keyCode),
        ]
        if let text {
            down["text"] = .string(text)
            down["unmodifiedText"] = .string(text)
        }
        let commands = commands(for: combo)
        if !commands.isEmpty { down["commands"] = .array(commands.map(JSON.string)) }
        let up: [String: JSON] = [
            "type": .string("keyUp"),
            "modifiers": .integer(mask),
            "key": .string(key.key),
            "code": .string(key.code),
            "windowsVirtualKeyCode": .integer(key.keyCode),
        ]
        return (down, up)
    }

    static func buttonName(_ button: MouseButton) -> String {
        button.rawValue
    }

    static func buttonMask(_ button: MouseButton) -> Int {
        switch button {
        case .left: return 1
        case .right: return 2
        case .middle: return 4
        }
    }
}
