import Foundation

/// A frame of a live view: a JPEG and the size of the coordinate space it shows.
public struct DisplayLiveViewFrame: Sendable, Hashable, Codable {
    public var jpeg: Data
    public var width: Int
    public var height: Int

    public init(jpeg: Data, width: Int, height: Int) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }
}

/// What a viewer sends while it has control. Points are in the frame's coordinate space.
public enum DisplayLiveViewInput: Sendable, Hashable, Codable {
    public enum MouseAction: String, Sendable, Hashable, Codable {
        case down
        case up
        case move
    }

    case mouse(MouseAction, x: Double, y: Double, button: MouseButton?, clickCount: Int, modifiers: Set<KeyModifier>)
    case wheel(x: Double, y: Double, dx: Double, dy: Double, modifiers: Set<KeyModifier>)
    case key(down: Bool, key: String, code: String, keyCode: Int, text: String?, modifiers: Set<KeyModifier>)
    /// Pasted text, inserted as if typed.
    case text(String)

    static let maxTextLength = 10_000

    private struct Wire: Decodable {
        var type: String
        var action: String?
        var x: Double?
        var y: Double?
        var button: String?
        var clickCount: Int?
        var dx: Double?
        var dy: Double?
        var key: String?
        var code: String?
        var keyCode: Int?
        var text: String?
        var modifiers: [String]?
    }

    /// Parses a viewer message; `nil` for anything malformed or out of range.
    init?(message: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: message) else { return nil }
        let modifiers = Set((wire.modifiers ?? []).compactMap { KeyModifier.aliases[$0.lowercased()] })
        func finite(_ values: Double?...) -> [Double]? {
            let unwrapped = values.compactMap { $0 }
            guard unwrapped.count == values.count, unwrapped.allSatisfy(\.isFinite) else { return nil }
            return unwrapped
        }
        switch wire.type {
        case "mouse":
            guard let action = wire.action.flatMap(MouseAction.init(rawValue:)), let point = finite(wire.x, wire.y) else { return nil }
            let button = wire.button.flatMap(MouseButton.init(rawValue:))
            if action != .move, button == nil { return nil }
            self = .mouse(action, x: point[0], y: point[1], button: button, clickCount: min(max(wire.clickCount ?? 1, 1), 3), modifiers: modifiers)
        case "wheel":
            guard let values = finite(wire.x, wire.y, wire.dx, wire.dy) else { return nil }
            self = .wheel(x: values[0], y: values[1], dx: values[2], dy: values[3], modifiers: modifiers)
        case "key":
            guard let action = wire.action, action == "down" || action == "up",
                  let key = wire.key, !key.isEmpty, key.count <= 32 else { return nil }
            let text = wire.text.flatMap { $0.isEmpty || $0.count > 4 ? nil : $0 }
            self = .key(down: action == "down", key: key, code: String((wire.code ?? "").prefix(32)), keyCode: wire.keyCode ?? 0, text: text, modifiers: modifiers)
        case "text":
            guard let text = wire.text, !text.isEmpty, text.count <= Self.maxTextLength else { return nil }
            self = .text(text)
        default:
            return nil
        }
    }
}

/// One target's side of a live view: told when viewers come and go, and handed their input while they have control.
public struct DisplayLiveViewFeed: Sendable {
    public var label: String
    /// Called with the new count whenever a viewer joins or leaves.
    public var viewersChanged: @Sendable (Int) async -> Void
    public var input: @Sendable (DisplayLiveViewInput) async -> Void

    public init(
        label: String,
        viewersChanged: @escaping @Sendable (Int) async -> Void = { _ in },
        input: @escaping @Sendable (DisplayLiveViewInput) async -> Void = { _ in }
    ) {
        self.label = label
        self.viewersChanged = viewersChanged
        self.input = input
    }
}
