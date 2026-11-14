import EasyJSON
import Foundation

/// A vendor's native computer-use tools, which its models are trained on.
///
/// Anthropic's newest version is a toolset of member tools; its older versions are a single `computer` tool whose
/// `action` field names the member. OpenAI's `computer` tool batches actions in one call. Gemini's `computer_use`
/// declares predefined functions, one action each. Coordinates are screenshot pixels for Anthropic and OpenAI and
/// a 0–999 grid for Gemini.
public enum ComputerUseNativeToolset: String, Sendable, Codable, Hashable, CaseIterable {
    case toolset20260801 = "computer_toolset_20260801"
    case computer20251124 = "computer_20251124"
    case computer20250124 = "computer_20250124"
    case openAIComputer = "computer"
    case geminiComputerUse = "computer_use"

    public enum Vendor: String, Sendable, Hashable {
        case anthropic, openAI, gemini
    }

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

    /// Gemini's predefined functions the harness can carry out. Holding a key or a mouse button down across calls,
    /// browser history, long presses, and listing apps have no canonical action, so they are excluded on the wire.
    static let geminiMemberNames = [
        "click", "double_click", "triple_click", "middle_click", "right_click", "mouse_down", "mouse_up", "move",
        "type", "drag_and_drop", "wait", "press_key", "hotkey", "take_screenshot", "scroll", "navigate", "open_app",
    ]
    static let geminiExcludedNames = ["key_down", "key_up", "go_back", "go_forward", "long_press", "list_apps"]

    /// `nil` for a version that isn't one of these.
    public init?(version: String?) {
        guard let version, let toolset = Self(rawValue: version) else { return nil }
        self = toolset
    }

    public var vendor: Vendor {
        switch self {
        case .toolset20260801, .computer20251124, .computer20250124: .anthropic
        case .openAIComputer: .openAI
        case .geminiComputerUse: .gemini
        }
    }

    /// The API the vendor serves this toolset on, when the feature names none.
    var defaultAPI: ComputerUseToolsetAPI {
        switch vendor {
        case .anthropic: .messages
        case .openAI: .responses
        case .gemini: .interactions
        }
    }

    /// The model protocol whose codec speaks this toolset.
    var modelProtocol: ModelProtocol {
        switch vendor {
        case .anthropic: .anthropic
        case .openAI: .openAIAPI
        case .gemini: .gemini
        }
    }

    public var isToolset: Bool { self == .toolset20260801 }

    /// The `anthropic-beta` header the request needs, if any.
    public var betaHeader: String? {
        switch self {
        case .toolset20260801, .openAIComputer, .geminiComputerUse: return nil
        case .computer20251124: return "computer-use-2025-11-24"
        case .computer20250124: return "computer-use-2025-01-24"
        }
    }

    public var supportsZoom: Bool { self == .toolset20260801 || self == .computer20251124 }

    public var memberNames: [String] {
        switch vendor {
        case .anthropic: supportsZoom ? Self.allMemberNames : Self.allMemberNames.filter { $0 != "zoom" }
        case .openAI: []
        case .gemini: Self.geminiMemberNames
        }
    }

    /// The tool names the harness registers for this version.
    public var registeredToolNames: Set<String> {
        switch vendor {
        case .anthropic: isToolset ? Set(memberNames) : [Self.name]
        case .openAI: [Self.name]
        case .gemini: Set(memberNames)
        }
    }

    /// Every name any version registers, for allow-lists and screen-content policy.
    public static var allRegisteredToolNames: Set<String> {
        Set(allMemberNames).union([name]).union(geminiMemberNames)
    }

    /// Names whose results can carry screenshots. Every Gemini action's result carries one.
    static var screenToolNames: Set<String> {
        screenMemberNames.union([name]).union(geminiMemberNames)
    }
}

/// The native toolset a specialist session speaks, carried to the vendor's codec in the request's additional
/// parameters.
public struct ComputerUseNativeDialect: Sendable, Hashable {
    public static let parameterKey = "computerUseNativeToolset"

    public var toolset: ComputerUseNativeToolset
    /// The screenshot size Anthropic's older versions declare; the others take none.
    public var displayWidthPx: Int?
    public var displayHeightPx: Int?
    /// Gemini's environment, which picks its predefined functions.
    public var environment: GeminiComputerEnvironment?
    /// The API the provider codec sends the session's requests to.
    public var api: ComputerUseToolsetAPI

    public init(
        toolset: ComputerUseNativeToolset,
        displayWidthPx: Int? = nil,
        displayHeightPx: Int? = nil,
        environment: GeminiComputerEnvironment? = nil,
        api: ComputerUseToolsetAPI? = nil
    ) {
        self.toolset = toolset
        self.displayWidthPx = displayWidthPx
        self.displayHeightPx = displayHeightPx
        self.environment = environment
        self.api = api ?? toolset.defaultAPI
    }

    public var wireParameters: JSON {
        var object: [String: JSON] = ["version": .string(toolset.rawValue)]
        if let displayWidthPx { object["displayWidthPx"] = .integer(displayWidthPx) }
        if let displayHeightPx { object["displayHeightPx"] = .integer(displayHeightPx) }
        if let environment { object["environment"] = .string(environment.rawValue) }
        object["api"] = .string(api.rawValue)
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
        var environment: GeminiComputerEnvironment?
        if case .string(let raw)? = object["environment"] { environment = GeminiComputerEnvironment(rawValue: raw) }
        var api: ComputerUseToolsetAPI?
        if case .string(let raw)? = object["api"] { api = ComputerUseToolsetAPI(rawValue: raw) }
        self.init(toolset: toolset, displayWidthPx: int("displayWidthPx"), displayHeightPx: int("displayHeightPx"), environment: environment, api: api)
    }

    /// The Gemini functions this dialect offers: its environment's predefined functions the harness can carry out.
    var geminiFunctionNames: [String] {
        let environment = environment ?? .browser
        return ComputerUseNativeToolset.geminiMemberNames.filter { environment.offers($0) }
    }

    /// The predefined functions to exclude on the wire: every one the harness can't carry out, or the environment's
    /// target doesn't support.
    var geminiExcludedFunctionNames: [String] {
        let offered = Set(geminiFunctionNames)
        let unsupported = ComputerUseNativeToolset.geminiMemberNames.filter { !offered.contains($0) }
        return ComputerUseNativeToolset.geminiExcludedNames + unsupported
    }

    /// The `tools` entry Anthropic expects for this version.
    public var declaration: [String: Any] {
        switch toolset {
        case .toolset20260801, .openAIComputer, .geminiComputerUse:
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

/// Gemini's computer-use environment.
public enum GeminiComputerEnvironment: String, Sendable, Hashable, Codable {
    case browser, desktop, mobile

    /// The environment for a target: a browser for pages, mobile for phones, and a desktop otherwise.
    public init(manifest: DisplayTargetManifest) {
        switch manifest.platform {
        case "chromium", "web", "browser": self = .browser
        case "android", "ios": self = .mobile
        default: self = .desktop
        }
    }

    func offers(_ function: String) -> Bool {
        switch self {
        case .browser: function != "open_app"
        case .desktop: function != "navigate" && function != "open_app"
        case .mobile: ["click", "type", "drag_and_drop", "press_key", "wait", "take_screenshot", "open_app"].contains(function)
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
