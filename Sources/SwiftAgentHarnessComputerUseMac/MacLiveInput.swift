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
}

/// A live viewer's input as event sequences. Pure, so the mapping is testable without posting anything.
enum MacLiveInput {
    static let domModifiers: [String: KeyModifier] = ["Shift": .shift, "Control": .ctrl, "Alt": .option, "Meta": .cmd, "Fn": .fn]

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
