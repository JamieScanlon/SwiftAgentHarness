import Foundation

/// Key names for `xdotool`: canonical key combos for agent actions, and DOM key values for live-view input.
enum X11Keys {
    static let modifierNames: [KeyModifier: String] = [.ctrl: "ctrl", .option: "alt", .shift: "shift", .cmd: "super"]

    static let keysyms: [String: String] = [
        "return": "Return", "escape": "Escape", "tab": "Tab", "space": "space", "delete": "BackSpace",
        "forward-delete": "Delete", "up": "Up", "down": "Down", "left": "Left", "right": "Right", "home": "Home",
        "end": "End", "page-up": "Prior", "page-down": "Next", "insert": "Insert", "capslock": "Caps_Lock",
        "-": "minus", "=": "equal", ",": "comma", ".": "period", "/": "slash", ";": "semicolon", "'": "apostrophe",
        "[": "bracketleft", "]": "bracketright", "\\": "backslash", "`": "grave", " ": "space",
    ]

    /// `ctrl+shift+a`-style chord for `xdotool key`, or `nil` for a key X has no name for here.
    static func chord(_ combo: KeyCombo) -> String? {
        guard let key = keysym(combo.key) else { return nil }
        let modifiers = combo.modifiers.sorted().compactMap { modifierNames[$0] }
        return (modifiers + [key]).joined(separator: "+")
    }

    static func keysym(_ key: String) -> String? {
        if let named = keysyms[key] { return named }
        if key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII,
           CharacterSet.alphanumerics.contains(scalar) {
            return key
        }
        if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...24).contains(number) { return "F\(number)" }
        return nil
    }

    static let domKeys: [String: String] = [
        "Enter": "Return", "Backspace": "BackSpace", "Tab": "Tab", "Escape": "Escape", "Delete": "Delete",
        "ArrowUp": "Up", "ArrowDown": "Down", "ArrowLeft": "Left", "ArrowRight": "Right", "Home": "Home", "End": "End",
        "PageUp": "Prior", "PageDown": "Next", "Insert": "Insert", "Shift": "Shift_L", "Control": "Control_L",
        "Alt": "Alt_L", "Meta": "Super_L", "CapsLock": "Caps_Lock",
    ]

    /// A DOM `KeyboardEvent.key` for a key that types no text, such as Enter or a function key.
    static func domKeysym(_ key: String) -> String? {
        if let named = domKeys[key] { return named }
        if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...24).contains(number) { return key }
        return nil
    }
}
