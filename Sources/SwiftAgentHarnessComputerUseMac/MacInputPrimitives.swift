#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// One coordinate space: CoreGraphics global display space, top-left origin of the primary display, y down, in
/// points. AX positions, ScreenCaptureKit frames, and CGEvent locations all use it; Cocoa rects are converted once.
enum MacCoordinateSpace {
    static func cgRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    static func cocoaRect(fromCG rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    static func cgRect(_ rect: DisplayRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    static func cgPoint(_ point: DisplayPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }
}

extension DisplayRect {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

extension DisplayPoint {
    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }
}

/// Canonical key combos to virtual key codes. The table is the US ANSI layout; apps that translate from the key
/// code under another layout may see different characters, which is why text goes through Unicode typing instead.
enum MacKeyMapping {
    struct KeyEvent: Equatable {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
    }

    static func event(for combo: KeyCombo) -> KeyEvent? {
        guard let code = keyCodes[combo.key] else { return nil }
        return KeyEvent(keyCode: code, flags: flags(for: combo.modifiers))
    }

    static func flags(for modifiers: some Sequence<KeyModifier>) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .cmd: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .ctrl: flags.insert(.maskControl)
            case .fn: flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    static func keyCode(for modifier: KeyModifier) -> CGKeyCode {
        switch modifier {
        case .cmd: return CGKeyCode(kVK_Command)
        case .shift: return CGKeyCode(kVK_Shift)
        case .option: return CGKeyCode(kVK_Option)
        case .ctrl: return CGKeyCode(kVK_Control)
        case .fn: return CGKeyCode(kVK_Function)
        }
    }

    static let keyCodes: [String: CGKeyCode] = {
        var table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
            "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete,
            "forward-delete": kVK_ForwardDelete, "escape": kVK_Escape,
            "home": kVK_Home, "end": kVK_End, "page-up": kVK_PageUp, "page-down": kVK_PageDown,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]
        for (index, code) in functionKeys.enumerated() {
            table["f\(index + 1)"] = code
        }
        return table.mapValues { CGKeyCode($0) }
    }()
}

/// Unicode typing in chunks small enough for one keyboard event, split only at grapheme boundaries. A single
/// grapheme larger than the limit is sent on its own rather than broken.
enum MacTextChunker {
    static let defaultMaxUTF16 = 20

    static func chunks(_ text: String, maxUTF16: Int = defaultMaxUTF16) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if currentUnits + units > maxUTF16, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
#endif
