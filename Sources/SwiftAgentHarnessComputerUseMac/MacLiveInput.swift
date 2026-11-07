#if os(macOS)
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// The screen a live frame showed: its display's rect in points and the frame's size in pixels, so a viewer's
/// points in the frame map back to the display.
struct MacLiveFrameSpace: Sendable, Equatable {
    var display: CGRect
    var frame: ImagePixelSize

    func point(_ x: Double, _ y: Double) -> CGPoint {
        let scaleX = display.width / CGFloat(max(frame.width, 1))
        let scaleY = display.height / CGFloat(max(frame.height, 1))
        let clampedX = min(max(x, 0), Double(frame.width - 1))
        let clampedY = min(max(y, 0), Double(frame.height - 1))
        return CGPoint(x: display.minX + CGFloat(clampedX) * scaleX, y: display.minY + CGFloat(clampedY) * scaleY)
    }

    /// `rect`, in display points, in the frame's pixels, counting rows from the top.
    func pixelRect(for rect: CGRect) -> CGRect {
        let scaleX = CGFloat(frame.width) / max(display.width, 1)
        let scaleY = CGFloat(frame.height) / max(display.height, 1)
        return CGRect(
            x: (rect.minX - display.minX) * scaleX,
            y: (rect.minY - display.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}

/// A live viewer's input as event sequences. Pure, so the mapping is testable without posting anything.
enum MacLiveInput {
    static let domModifiers: [String: KeyModifier] = ["Shift": .shift, "Control": .ctrl, "Alt": .option, "Meta": .cmd, "Fn": .fn]

    /// The physical keys whose DOM `code` names a key the harness knows. Option changes the character a key types on
    /// a Mac (⌥. is ≥), so a combo is also read from the key's code.
    static let codeKeys: [String: String] = [
        "Period": ".", "Comma": ",", "Slash": "/", "Semicolon": ";", "Quote": "'", "BracketLeft": "[", "BracketRight": "]",
        "Backslash": "\\", "Minus": "-", "Equal": "=", "Backquote": "`", "Space": "space", "Tab": "tab", "Escape": "escape",
        "Enter": "return", "Backspace": "delete", "Delete": "forward-delete",
    ]

    /// The combos a viewer's key could be: by the key it typed and by the physical key. None for a modifier alone.
    static func combos(key: String, code: String, modifiers: Set<KeyModifier>) -> [KeyCombo] {
        guard domModifiers[key] == nil else { return [] }
        let named = key == " " ? "space" : key == "Delete" ? "forward-delete" : key == "Backspace" ? "delete" : key
        var combos = [KeyCombo(modifiers: modifiers, key: named)]
        let physical: String? = if code.hasPrefix("Key"), code.count == 4 {
            code.suffix(1).lowercased()
        } else if code.hasPrefix("Digit"), code.count == 6 {
            String(code.suffix(1))
        } else {
            codeKeys[code]
        }
        if let physical {
            let combo = KeyCombo(modifiers: modifiers, key: physical)
            if !combos.contains(combo) { combos.append(combo) }
        }
        return combos
    }

    /// `held` is the mouse button the viewer is holding, if any, so moves while it is down become drags.
    static func events(for input: DisplayLiveViewInput, space: MacLiveFrameSpace, held: MouseButton?) -> [MacInputEvent] {
        switch input {
        case .mouse(let action, let x, let y, let button, let clickCount, let modifiers):
            let point = space.point(x, y)
            let flags = MacKeyMapping.flags(for: modifiers)
            switch action {
            case .move:
                return [held.map { .mouseDrag(point, $0, flags) } ?? .mouseMove(point)]
            case .down:
                guard let button else { return [] }
                return [.mouseMove(point), .mouseDown(point, button, clickCount, flags)]
            case .up:
                guard let button else { return [] }
                return [.mouseUp(point, button, clickCount, flags)]
            }
        case .wheel(let x, let y, let dx, let dy, _):
            // A page scrolls down for a positive DOM delta; a positive wheel value scrolls up.
            return [.scroll(at: space.point(x, y), wheelY: Int32(clamping: Int(-dy.rounded())), wheelX: Int32(clamping: Int(-dx.rounded())), unit: .pixel)]
        case .key(let down, let key, _, _, let text, let modifiers):
            if let modifier = domModifiers[key] {
                let code = MacKeyMapping.keyCode(for: modifier)
                return [down ? .keyDown(code, MacKeyMapping.flags(for: modifiers)) : .keyUp(code, MacKeyMapping.flags(for: modifiers))]
            }
            // A character is typed on its way down, which handles layout and shift; its release isn't sent.
            if let text, key.count == 1, modifiers.isDisjoint(with: [.ctrl, .cmd]) {
                return down ? [.unicode(text)] : []
            }
            // DOM's Delete is forward delete; its Backspace is the harness's delete.
            let name = key == " " ? "space" : key == "Delete" ? "forward-delete" : key
            guard let event = MacKeyMapping.event(for: KeyCombo(modifiers: modifiers, key: name)) else { return [] }
            return [down ? .keyDown(event.keyCode, event.flags) : .keyUp(event.keyCode, event.flags)]
        case .text(let text):
            return MacTextChunker.chunks(text).map { .unicode($0) }
        }
    }
}
#endif
