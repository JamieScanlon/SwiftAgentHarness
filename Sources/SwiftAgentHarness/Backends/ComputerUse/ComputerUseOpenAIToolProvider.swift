import EasyJSON
import Foundation
import SwiftAgentKit

/// OpenAI's `computer` tool, executed against a leased session. A call is a batch of actions in screenshot pixels;
/// each becomes a canonical action the session gates like any other, and the result is the screenshot after the
/// batch. Pending safety checks are a question for the user before the batch's first action.
///
/// The tool definition registers the name with the tool system. The OpenAI codec replaces it on the wire with the
/// vendor declaration, and carries the call's `actions` and `pending_safety_checks` in its arguments.
struct ComputerUseOpenAIToolProvider: ToolProvider, ToolDescriptorHinting {
    let session: ComputerUseSession
    let failures: ComputerUseNativeFailures

    /// The result line telling the codec to acknowledge the call's pending safety checks.
    static let acknowledgedLine = "The user confirmed the pending safety checks."

    var name: String { "ComputerUseOpenAI" }

    private var support: ComputerUseVendorToolSupport { ComputerUseVendorToolSupport(session: session, failures: failures) }

    var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        ComputerUseVendorToolSupport.hints(for: [ComputerUseNativeToolset.name])
    }

    func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        ComputerUseVendorToolSupport.policyTags()
    }

    func availableTools() async -> [ToolDefinition] {
        [ToolDefinition(
            name: ComputerUseNativeToolset.name,
            description: "OpenAI computer use: a batch of actions in screenshot pixels.",
            parameters: [
                .init(name: "actions", description: "click, double_click, drag, move, scroll, keypress, type, wait, or screenshot.", type: "array", required: true),
                .init(name: "pending_safety_checks", description: "The vendor's safety checks on this call.", type: "array", required: false),
            ],
            type: .function
        )]
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        guard toolCall.name == ComputerUseNativeToolset.name else {
            return await support.failure(toolCall, "\(toolCall.name) isn't OpenAI's computer tool")
        }
        let arguments = ComputerUseVendorToolSupport.fields(toolCall.arguments)
        var rawActions: [JSON] = []
        if case .array(let values)? = arguments["actions"] {
            rawActions = values
        } else if let single = arguments["action"] {
            rawActions = [single]
        }
        let signals = Self.signals(arguments["pending_safety_checks"])
        var actions: [ComputerAction] = []
        do {
            for raw in rawActions {
                actions += try await canonicalActions(ComputerUseVendorToolSupport.fields(raw))
            }
        } catch let failure as ComputerUseVendorToolSupport.Failure {
            return await support.failure(toolCall, failure.message)
        }

        let report = await support.run(actions, signals: signals, toolCallID: toolCall.id)
        var lines: [String] = []
        if report.acknowledged { lines.append(Self.acknowledgedLine) }
        lines += report.notes
        if let reminder = report.reminder { lines.append(reminder) }
        return support.result(toolCall, text: lines.isEmpty ? "OK" : lines.joined(separator: "\n"), screenshot: report.screenshot)
    }

    static func signals(_ json: JSON?) -> [ComputerUseSafetySignal] {
        guard case .array(let checks)? = json else { return [] }
        return checks.map { check in
            let code = ComputerUseVendorToolSupport.string(ComputerUseVendorToolSupport.fields(check)["code"])
            return code.map(ComputerUseSafetySignal.init(openAISafetyCheckCode:)) ?? .other("unspecified")
        }
    }

    private func canonicalActions(_ action: [String: JSON]) async throws -> [ComputerAction] {
        typealias Support = ComputerUseVendorToolSupport
        let type = Support.string(action["type"]) ?? ""
        let modifiers = try Self.modifiers(action["keys"], for: type)
        switch type {
        case "screenshot":
            return []
        case "click":
            let button: MouseButton
            switch Support.string(action["button"]) ?? "left" {
            case "left": button = .left
            case "right": button = .right
            case "wheel", "middle": button = .middle
            case let other: throw Support.Failure("the \(other) button isn't supported")
            }
            return [.click(at: try await support.point(action["x"], action["y"]), button: button, modifiers: modifiers)]
        case "double_click":
            return [.click(at: try await support.point(action["x"], action["y"]), count: 2, modifiers: modifiers)]
        case "move":
            guard modifiers.isEmpty else { throw Support.Failure("holding keys while moving isn't supported") }
            return [.move(to: try await support.point(action["x"], action["y"]))]
        case "drag":
            guard case .array(let path)? = action["path"], path.count >= 2 else { throw Support.Failure("drag needs a path of at least 2 points") }
            var targets: [ActionTarget] = []
            for point in path {
                if case .array(let pair) = point, pair.count == 2 {
                    targets.append(try await support.point(pair[0], pair[1]))
                } else {
                    let fields = Support.fields(point)
                    targets.append(try await support.point(fields["x"], fields["y"]))
                }
            }
            return [.drag(path: targets, modifiers: modifiers)]
        case "scroll":
            guard modifiers.isEmpty else { throw Support.Failure("holding keys while scrolling isn't supported") }
            let at = try await support.point(action["x"], action["y"])
            let scale = try await support.unitScale()
            let dx = (Support.number(action["scroll_x"]) ?? 0) * scale.x
            let dy = (Support.number(action["scroll_y"]) ?? 0) * scale.y
            return [.scroll(at: at, dx: dx, dy: dy, unit: .pixel)]
        case "keypress":
            guard case .array(let keys)? = action["keys"] else { throw Support.Failure("keypress needs keys") }
            return [.key(combo: try Support.keyCombo(keys.compactMap { Support.string($0) }))]
        case "type":
            guard let text = Support.string(action["text"]) else { throw Support.Failure("type needs text") }
            return [.type(text: text)]
        case "wait":
            return [.wait(milliseconds: 2_000)]
        default:
            throw Support.Failure("\"\(type)\" isn't a computer action")
        }
    }

    private static func modifiers(_ json: JSON?, for type: String) throws -> [KeyModifier] {
        guard type != "keypress", case .array(let keys)? = json else { return [] }
        return try keys.compactMap { ComputerUseVendorToolSupport.string($0) }.map { key in
            guard let modifier = KeyModifier.aliases[key.lowercased()] else {
                throw ComputerUseVendorToolSupport.Failure("\"\(key)\" isn't a modifier key")
            }
            return modifier
        }
    }
}
