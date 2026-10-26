import EasyJSON
import Foundation

/// Anthropic's native computer-use tools, which Claude is trained on. The newest is a toolset of member tools;
/// the older versions are a single `computer` tool whose `action` field names the member. Coordinates are
/// screenshot pixels in every version.
public enum ComputerUseNativeToolset: String, Sendable, Codable, Hashable, CaseIterable {
    case toolset20260801 = "computer_toolset_20260801"
    case computer20251124 = "computer_20251124"
    case computer20250124 = "computer_20250124"

    /// The `toolset_name` calls and results carry, and the older versions' tool name.
    public static let name = "computer"
    /// The result for each action after the first failure in a batch.
    public static let haltText = "Not executed: an earlier computer action in this turn failed."

    static let allMemberNames = [
        "screenshot", "zoom", "left_click", "right_click", "middle_click", "double_click", "triple_click",
        "left_click_drag", "mouse_move", "left_mouse_down", "left_mouse_up", "cursor_position", "scroll", "type",
        "key", "hold_key", "wait",
    ]
    /// Members whose results carry screen content.
    static let screenMemberNames: Set<String> = ["screenshot", "zoom"]

    /// `nil` for a version that isn't one of these.
    public init?(version: String?) {
        guard let version, let toolset = Self(rawValue: version) else { return nil }
        self = toolset
    }

    public var isToolset: Bool { self == .toolset20260801 }

    /// The `anthropic-beta` header the request needs, if any.
    public var betaHeader: String? {
        switch self {
        case .toolset20260801: return nil
        case .computer20251124: return "computer-use-2025-11-24"
        case .computer20250124: return "computer-use-2025-01-24"
        }
    }

    public var supportsZoom: Bool { self != .computer20250124 }

    public var memberNames: [String] {
        supportsZoom ? Self.allMemberNames : Self.allMemberNames.filter { $0 != "zoom" }
    }

    /// The tool names the harness registers for this version.
    public var registeredToolNames: Set<String> {
        isToolset ? Set(memberNames) : [Self.name]
    }

    /// Every name any version registers, for allow-lists and screen-content policy.
    public static var allRegisteredToolNames: Set<String> {
        Set(allMemberNames).union([name])
    }

    /// Names whose results can carry screenshots.
    static var screenToolNames: Set<String> {
        screenMemberNames.union([name])
    }
}

/// The native toolset a specialist session speaks, carried to the Anthropic codec in the request's additional
/// parameters.
public struct ComputerUseNativeDialect: Sendable, Hashable {
    public static let parameterKey = "computerUseNativeToolset"

    public var toolset: ComputerUseNativeToolset
    /// The screenshot size the older versions declare; the toolset takes none.
    public var displayWidthPx: Int?
    public var displayHeightPx: Int?

    public init(toolset: ComputerUseNativeToolset, displayWidthPx: Int? = nil, displayHeightPx: Int? = nil) {
        self.toolset = toolset
        self.displayWidthPx = displayWidthPx
        self.displayHeightPx = displayHeightPx
    }

    public var wireParameters: JSON {
        var object: [String: JSON] = ["version": .string(toolset.rawValue)]
        if let displayWidthPx { object["displayWidthPx"] = .integer(displayWidthPx) }
        if let displayHeightPx { object["displayHeightPx"] = .integer(displayHeightPx) }
        return .object(object)
    }

    /// The dialect in a request's additional parameters, if any.
    public init?(additionalParameters: JSON?) {
        guard case .object(let root)? = additionalParameters,
              case .object(let object)? = root[Self.parameterKey],
              case .string(let version)? = object["version"],
              let toolset = ComputerUseNativeToolset(version: version)
        else { return nil }
        func int(_ key: String) -> Int? {
            if case .integer(let value)? = object[key] { return value }
            return nil
        }
        self.init(toolset: toolset, displayWidthPx: int("displayWidthPx"), displayHeightPx: int("displayHeightPx"))
    }

    /// The `tools` entry Anthropic expects for this version.
    public var declaration: [String: Any] {
        switch toolset {
        case .toolset20260801:
            return ["type": toolset.rawValue]
        case .computer20251124, .computer20250124:
            var entry: [String: Any] = [
                "type": toolset.rawValue,
                "name": ComputerUseNativeToolset.name,
                "display_width_px": displayWidthPx ?? 1_280,
                "display_height_px": displayHeightPx ?? 800,
            ]
            if toolset == .computer20251124 { entry["enable_zoom"] = true }
            return entry
        }
    }
}

/// Failed native calls, by tool-call id, so the agent loop can halt the rest of the model's batch.
actor ComputerUseNativeFailures {
    private var failed: Set<String> = []

    func recordFailure(toolCallID: String) {
        failed.insert(toolCallID)
    }

    /// Whether the call failed; the record is consumed.
    func takeFailure(toolCallID: String) -> Bool {
        failed.remove(toolCallID) != nil
    }
}
