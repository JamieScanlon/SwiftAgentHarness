import EasyJSON
import Foundation
import SwiftAgentKit

/// Gemini's predefined computer-use functions, executed against a leased session. Each call is one action on the
/// 0–999 grid; it becomes canonical actions the session gates like any other, and its result is the page URL as JSON
/// plus the screenshot after it. A `safety_decision` asking for confirmation is a question for the user before the
/// action, and `safety_acknowledgement` is reported only when the user said yes.
///
/// The tool definitions register the names with the tool system. The Gemini codec replaces them on the wire with
/// the vendor's `computer_use` declaration.
struct ComputerUseGeminiToolProvider: ToolProvider, ToolDescriptorHinting {
    let session: ComputerUseSession
    let dialect: ComputerUseNativeDialect
    let failures: ComputerUseNativeFailures

    var name: String { "ComputerUseGemini" }

    private var support: ComputerUseVendorToolSupport { ComputerUseVendorToolSupport(session: session, failures: failures) }

    var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        ComputerUseVendorToolSupport.hints(for: Set(dialect.geminiFunctionNames))
    }

    func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        ComputerUseVendorToolSupport.policyTags()
    }

    func availableTools() async -> [ToolDefinition] {
        let x = ToolDefinition.Parameter(name: "x", description: "0–999 across the screenshot.", type: "integer", required: true)
        let y = ToolDefinition.Parameter(name: "y", description: "0–999 down the screenshot.", type: "integer", required: true)
        let intent = ToolDefinition.Parameter(name: "intent", description: "Why the action is taken.", type: "string", required: false)
        return dialect.geminiFunctionNames.map { function in
            var parameters: [ToolDefinition.Parameter]
            switch function {
            case "click", "double_click", "triple_click", "middle_click", "right_click", "mouse_down", "mouse_up", "move":
                parameters = [x, y]
            case "type":
                parameters = [
                    .init(name: "text", description: "Text to type.", type: "string", required: true),
                    .init(name: "press_enter", description: "Press Enter afterwards.", type: "boolean", required: false),
                ]
            case "drag_and_drop":
                parameters = ["start_x", "start_y", "end_x", "end_y"].map {
                    .init(name: $0, description: "0–999 grid coordinate.", type: "integer", required: true)
                }
            case "wait":
                parameters = [.init(name: "seconds", description: "Seconds to wait.", type: "integer", required: false)]
            case "press_key":
                parameters = [.init(name: "key", description: "The key.", type: "string", required: true)]
            case "hotkey":
                parameters = [.init(name: "keys", description: "Keys pressed together.", type: "array", required: true)]
            case "scroll":
                parameters = [
                    .init(name: "x", description: "0–999 across the screenshot.", type: "integer", required: false),
                    .init(name: "y", description: "0–999 down the screenshot.", type: "integer", required: false),
                    .init(name: "direction", description: "up, down, left, or right.", type: "string", required: true),
                    .init(name: "magnitude_in_pixels", description: "How far to scroll.", type: "integer", required: false),
                ]
            case "navigate":
                parameters = [.init(name: "url", description: "The URL to open.", type: "string", required: true)]
            case "open_app":
                parameters = [.init(name: "app_name", description: "The app to open.", type: "string", required: true)]
            default:
                parameters = []
            }
            return ToolDefinition(name: function, description: "Gemini computer use: \(function).", parameters: parameters + [intent], type: .function)
        }
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        guard dialect.geminiFunctionNames.contains(toolCall.name) else {
            return await support.failure(toolCall, "\(toolCall.name) isn't one of Gemini's computer-use functions here")
        }
        let arguments = ComputerUseVendorToolSupport.fields(toolCall.arguments)
        let signals = Self.signals(arguments["safety_decision"])
        let actions: [ComputerAction]
        do {
            actions = try await canonicalActions(toolCall.name, arguments)
        } catch let failure as ComputerUseVendorToolSupport.Failure {
            return await support.failure(toolCall, failure.message)
        }

        let report = await support.run(actions, signals: signals, toolCallID: toolCall.id)
        var response: [String: JSON] = [:]
        if let url = report.screenshot?.target.url { response["url"] = .string(url) }
        if report.acknowledged { response["safety_acknowledgement"] = .boolean(true) }
        if report.failed || !report.notes.isEmpty { response["error"] = .string(report.notes.joined(separator: "; ")) }
        if let reminder = report.reminder { response["note"] = .string(reminder) }
        return support.result(toolCall, text: Self.text(response), screenshot: report.screenshot)
    }

    static func signals(_ json: JSON?) -> [ComputerUseSafetySignal] {
        let decision = ComputerUseVendorToolSupport.string(ComputerUseVendorToolSupport.fields(json)["decision"])
        return decision.flatMap(ComputerUseSafetySignal.init(geminiSafetyDecision:)).map { [$0] } ?? []
    }

    private static func text(_ object: [String: JSON]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(JSON.object(object))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func canonicalActions(_ function: String, _ arguments: [String: JSON]) async throws -> [ComputerAction] {
        typealias Support = ComputerUseVendorToolSupport
        switch function {
        case "take_screenshot":
            return []
        case "click", "double_click", "triple_click", "middle_click", "right_click":
            let at = try await support.point(arguments["x"], arguments["y"])
            let button: MouseButton = function == "middle_click" ? .middle : function == "right_click" ? .right : .left
            let count = function == "double_click" ? 2 : function == "triple_click" ? 3 : 1
            return [.click(at: at, button: button, count: count)]
        case "mouse_down", "mouse_up":
            return [.move(to: try await support.point(arguments["x"], arguments["y"])), .pointer(state: function == "mouse_down" ? .down : .up)]
        case "move":
            return [.move(to: try await support.point(arguments["x"], arguments["y"]))]
        case "type":
            guard let text = Support.string(arguments["text"]) else { throw Support.Failure("type needs text") }
            let into = arguments["x"] != nil ? try await support.point(arguments["x"], arguments["y"]) : nil
            var actions: [ComputerAction] = [.type(text: text, into: into)]
            if Support.bool(arguments["press_enter"]) { actions.append(.key(combo: KeyCombo(modifiers: [], key: "return"))) }
            return actions
        case "drag_and_drop":
            let start = try await support.point(arguments["start_x"], arguments["start_y"])
            let end = try await support.point(arguments["end_x"], arguments["end_y"])
            return [.drag(path: [start, end])]
        case "wait":
            let seconds = Support.number(arguments["seconds"]) ?? 1
            guard seconds >= 0, seconds <= 300 else { throw Support.Failure("wait takes 0 to 300 seconds") }
            return [.wait(milliseconds: Int((seconds * 1_000).rounded()))]
        case "press_key":
            guard let key = Support.string(arguments["key"]) else { throw Support.Failure("press_key needs a key") }
            return [.key(combo: try Support.keyCombo([key]))]
        case "hotkey":
            guard case .array(let keys)? = arguments["keys"] else { throw Support.Failure("hotkey needs keys") }
            return [.key(combo: try Support.keyCombo(keys.compactMap { Support.string($0) }))]
        case "scroll":
            let at = arguments["x"] != nil ? try await support.point(arguments["x"], arguments["y"]) : nil
            // The magnitude is taken on the grid the coordinates use, so it scales with the screenshot.
            let magnitude = Support.number(arguments["magnitude_in_pixels"]) ?? 300
            let scale = try await support.unitScale()
            switch Support.string(arguments["direction"])?.lowercased() {
            case "up": return [.scroll(at: at, dx: 0, dy: -magnitude * scale.y, unit: .pixel)]
            case "down": return [.scroll(at: at, dx: 0, dy: magnitude * scale.y, unit: .pixel)]
            case "left": return [.scroll(at: at, dx: -magnitude * scale.x, dy: 0, unit: .pixel)]
            case "right": return [.scroll(at: at, dx: magnitude * scale.x, dy: 0, unit: .pixel)]
            default: throw Support.Failure("direction must be up, down, left, or right")
            }
        case "navigate":
            guard let url = Support.string(arguments["url"]) else { throw Support.Failure("navigate needs a url") }
            return [.openURL(url)]
        case "open_app":
            guard let app = Support.string(arguments["app_name"]) else { throw Support.Failure("open_app needs app_name") }
            return [.launch(app: app)]
        default:
            throw Support.Failure("\(function) isn't supported")
        }
    }
}
