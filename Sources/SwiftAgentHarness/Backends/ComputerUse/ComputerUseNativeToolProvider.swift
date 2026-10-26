import EasyJSON
import Foundation
import SwiftAgentKit

/// Anthropic's native computer-use members, executed against a leased session. Each call becomes a canonical
/// action the session gates like any other: classification, the intent check, confirmation, and budgets all
/// apply. Coordinates are pixels of the latest screenshot.
///
/// The tool definitions here register the names with the tool system. The Anthropic codec replaces them on the
/// wire with the vendor declaration (see ``ComputerUseNativeDialect``).
struct ComputerUseNativeToolProvider: ToolProvider, ToolDescriptorHinting {
    let session: ComputerUseSession
    let toolset: ComputerUseNativeToolset
    let failures: ComputerUseNativeFailures

    var name: String { "ComputerUseNative" }

    private enum Failure: Error {
        case message(String)
    }

    var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        let readOnly: Set<String> = ["screenshot", "zoom", "cursor_position", "wait"]
        return Dictionary(uniqueKeysWithValues: toolset.registeredToolNames.map { name in
            (name, ToolDescriptorHints(
                effectClass: readOnly.contains(name) ? .readOnly : .mutating,
                parallelHint: .serialOnly,
                policyTags: policyTags(forName: name)
            ))
        })
    }

    func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        policyTags(forName: definition.name)
    }

    private func policyTags(forName name: String) -> [ToolPolicyTag] {
        var tags = [ToolPolicyTag(rawValue: ToolRegistryEntry.PolicyTag.haltsBatchOnFailure.rawValue)]
        if ComputerUseNativeToolset.screenToolNames.contains(name) {
            tags.append(ToolRegistryResultFormattingPolicy.geometryBoundImagesPolicyTag())
        }
        return tags
    }

    func availableTools() async -> [ToolDefinition] {
        let coordinate = ToolDefinition.Parameter(
            name: "coordinate", description: "[x, y] in screenshot pixels.", type: "array", required: false
        )
        let modifiers = ToolDefinition.Parameter(
            name: "text", description: "Modifier keys held during the action, joined with +.", type: "string", required: false
        )
        guard toolset.isToolset else {
            return [ToolDefinition(
                name: ComputerUseNativeToolset.name,
                description: "Anthropic computer use: one action per call, named by action.",
                parameters: [
                    .init(name: "action", description: "The action: \(toolset.memberNames.joined(separator: ", ")).", type: "string", required: true),
                    coordinate,
                    .init(name: "start_coordinate", description: "[x, y] where a drag starts.", type: "array", required: false),
                    .init(name: "text", description: "Text to type, a key combo, or modifiers.", type: "string", required: false),
                    .init(name: "region", description: "[x0, y0, x1, y1] to zoom.", type: "array", required: false),
                    .init(name: "scroll_direction", description: "up, down, left, or right.", type: "string", required: false),
                    .init(name: "scroll_amount", description: "How far to scroll.", type: "number", required: false),
                    .init(name: "duration", description: "Seconds to wait or hold.", type: "number", required: false),
                    .init(name: "repeat", description: "Times to press the key.", type: "integer", required: false),
                ],
                type: .function
            )]
        }
        return toolset.memberNames.map { member in
            var parameters: [ToolDefinition.Parameter] = []
            switch member {
            case "zoom":
                parameters = [.init(name: "region", description: "[x0, y0, x1, y1] in screenshot pixels.", type: "array", required: true)]
            case "left_click", "right_click", "middle_click", "double_click", "triple_click":
                parameters = [coordinate, modifiers]
            case "left_click_drag":
                parameters = [
                    .init(name: "start_coordinate", description: "[x, y] where the drag starts.", type: "array", required: true),
                    .init(name: "coordinate", description: "[x, y] where the drag ends.", type: "array", required: true),
                    modifiers,
                ]
            case "mouse_move":
                parameters = [.init(name: "coordinate", description: "[x, y] in screenshot pixels.", type: "array", required: true)]
            case "scroll":
                parameters = [
                    .init(name: "scroll_direction", description: "up, down, left, or right.", type: "string", required: true),
                    .init(name: "scroll_amount", description: "How far to scroll.", type: "number", required: true),
                    coordinate,
                    modifiers,
                ]
            case "type":
                parameters = [.init(name: "text", description: "Text to type.", type: "string", required: true)]
            case "key":
                parameters = [
                    .init(name: "text", description: "A key or +-joined combo.", type: "string", required: true),
                    .init(name: "repeat", description: "Times to press it, 1–100.", type: "integer", required: false),
                ]
            case "hold_key":
                parameters = [
                    .init(name: "text", description: "A key or +-joined combo.", type: "string", required: true),
                    .init(name: "duration", description: "Seconds to hold it.", type: "number", required: true),
                ]
            case "wait":
                parameters = [.init(name: "duration", description: "Seconds to wait.", type: "number", required: true)]
            default:
                break
            }
            return ToolDefinition(name: member, description: "Anthropic computer use: \(member).", parameters: parameters, type: .function)
        }
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        let arguments = Self.fields(toolCall.arguments)
        let member: String
        if toolset.isToolset {
            member = toolCall.name
        } else if case .string(let action)? = arguments["action"] {
            member = action
        } else {
            return await failure(toolCall, "the computer tool needs an action")
        }
        guard toolset.memberNames.contains(member), toolset.registeredToolNames.contains(toolCall.name) else {
            return await failure(toolCall, "\(member) isn't an action of \(toolset.rawValue)")
        }
        do {
            return try await execute(member, arguments: arguments, toolCall: toolCall)
        } catch Failure.message(let message) {
            return await failure(toolCall, message)
        }
    }

    private func execute(_ member: String, arguments: [String: JSON], toolCall: ToolCall) async throws -> ToolResult {
        switch member {
        case "screenshot":
            let batch = await session.perform([.observe(ObserveRequest(modes: [.pixels], scope: .display(nil)))])
            return try await observationResult(batch, toolCall: toolCall)
        case "zoom":
            let screenshot = try latest(await session.latestScreenshot)
            let region = try rect(arguments["region"], in: screenshot)
            let batch = await session.perform([.zoom(region: region, observation: screenshot.id)])
            return try await observationResult(batch, toolCall: toolCall)
        case "cursor_position":
            let screenshot = try latest(await session.latestScreenshot)
            guard let pointer = await session.lastPointer, let geometry = screenshot.image?.geometry else {
                throw Failure.message("the pointer position isn't known yet; move or click first")
            }
            let pixel = geometry.toImage(pointer)
            return await success(toolCall, "X=\(Int(pixel.x.rounded())), Y=\(Int(pixel.y.rounded()))")
        default:
            let action = try await canonicalAction(member, arguments: arguments)
            let batch = await session.perform([action])
            guard let outcome = batch.outcomes.first else { throw Failure.message("the action produced no outcome") }
            switch outcome.effect {
            case .refused, .notExecuted:
                throw Failure.message(outcome.evidence ?? "the action was refused")
            default:
                let detail = outcome.evidence.map { " (\(outcome.effect.rawValue): \($0))" } ?? ""
                return await success(toolCall, "OK" + detail)
            }
        }
    }

    private func canonicalAction(_ member: String, arguments: [String: JSON]) async throws -> ComputerAction {
        switch member {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let button: MouseButton = member == "right_click" ? .right : member == "middle_click" ? .middle : .left
            let count = member == "double_click" ? 2 : member == "triple_click" ? 3 : 1
            let target = try await pointTarget(arguments["coordinate"], orPointer: true)
            return .click(at: target, button: button, count: count, modifiers: try modifiers(arguments["text"]))
        case "left_click_drag":
            let start = try await pointTarget(arguments["start_coordinate"], orPointer: false)
            let end = try await pointTarget(arguments["coordinate"], orPointer: false)
            return .drag(path: [start, end], modifiers: try modifiers(arguments["text"]))
        case "mouse_move":
            return .move(to: try await pointTarget(arguments["coordinate"], orPointer: false))
        case "left_mouse_down":
            return .pointer(state: .down)
        case "left_mouse_up":
            return .pointer(state: .up)
        case "scroll":
            guard case .string(let direction)? = arguments["scroll_direction"] else { throw Failure.message("scroll needs scroll_direction") }
            guard let amount = Self.number(arguments["scroll_amount"]) else { throw Failure.message("scroll needs scroll_amount") }
            let at = arguments["coordinate"] == nil ? nil : try await pointTarget(arguments["coordinate"], orPointer: false)
            switch direction.lowercased() {
            case "up": return .scroll(at: at, dx: 0, dy: -amount, unit: .line)
            case "down": return .scroll(at: at, dx: 0, dy: amount, unit: .line)
            case "left": return .scroll(at: at, dx: -amount, dy: 0, unit: .line)
            case "right": return .scroll(at: at, dx: amount, dy: 0, unit: .line)
            default: throw Failure.message("scroll_direction must be up, down, left, or right")
            }
        case "type":
            guard case .string(let text)? = arguments["text"] else { throw Failure.message("type needs text") }
            return .type(text: text)
        case "key":
            let combo = try keyCombo(arguments["text"])
            let count = Self.number(arguments["repeat"]).map { Int($0) } ?? 1
            guard (1...100).contains(count) else { throw Failure.message("repeat must be 1 to 100") }
            return .key(combo: combo, repeatCount: count)
        case "hold_key":
            let combo = try keyCombo(arguments["text"])
            guard let seconds = Self.number(arguments["duration"]), seconds >= 0, seconds <= 300 else {
                throw Failure.message("hold_key needs a duration of 0 to 300 seconds")
            }
            return .hold(combo: combo, milliseconds: Int((seconds * 1_000).rounded()))
        case "wait":
            guard let seconds = Self.number(arguments["duration"]), seconds >= 0, seconds <= 300 else {
                throw Failure.message("wait needs a duration of 0 to 300 seconds")
            }
            return .wait(milliseconds: Int((seconds * 1_000).rounded()))
        default:
            throw Failure.message("\(member) isn't supported")
        }
    }

    // MARK: - Coordinates

    private func latest(_ screenshot: DisplayObservation?) throws -> DisplayObservation {
        guard let screenshot, screenshot.image != nil else { throw Failure.message("take a screenshot first") }
        return screenshot
    }

    /// A point target from `[x, y]` screenshot pixels, or the current pointer when `orPointer` and it's absent.
    private func pointTarget(_ json: JSON?, orPointer: Bool) async throws -> ActionTarget {
        let screenshot = try latest(await session.latestScreenshot)
        guard let geometry = screenshot.image?.geometry else { throw Failure.message("take a screenshot first") }
        guard let json else {
            guard orPointer, let pointer = await session.lastPointer else { throw Failure.message("a coordinate is required") }
            return .point(pointer, observation: screenshot.id)
        }
        guard let values = Self.numbers(json), values.count == 2 else { throw Failure.message("a coordinate is [x, y]") }
        do {
            return .point(try session.coordinateCodec.decode(x: values[0], y: values[1], geometry: geometry), observation: screenshot.id)
        } catch {
            throw Failure.message("[\(Int(values[0])), \(Int(values[1]))] is outside the screenshot")
        }
    }

    private func rect(_ json: JSON?, in screenshot: DisplayObservation) throws -> DisplayRect {
        guard let geometry = screenshot.image?.geometry,
              let json, let values = Self.numbers(json), values.count == 4,
              values[2] > values[0], values[3] > values[1]
        else { throw Failure.message("region is [x0, y0, x1, y1] with x1 > x0 and y1 > y0") }
        let origin = geometry.toGlobal(DisplayPoint(x: values[0], y: values[1]))
        let corner = geometry.toGlobal(DisplayPoint(x: values[2], y: values[3]))
        return DisplayRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
    }

    // MARK: - Keys

    /// X11 key names, as Claude writes them, mapped to the harness's: `Delete` is forward delete, `BackSpace`
    /// is delete, and underscores become hyphens (`Page_Down`).
    private func keyCombo(_ json: JSON?) throws -> KeyCombo {
        guard case .string(let raw)? = json else { throw Failure.message("a key is required") }
        let parts = raw.split(separator: "+", omittingEmptySubsequences: false).map { part -> String in
            let lowered = part.trimmingCharacters(in: .whitespaces).lowercased()
            if lowered == "delete" { return "forward-delete" }
            return lowered.replacingOccurrences(of: "_", with: "-")
        }
        do {
            return try KeyCombo(parsing: parts.joined(separator: "+"))
        } catch KeyComboParseError.missingKey {
            throw Failure.message("\"\(raw)\" has no key besides modifiers; pass modifiers in a click's text instead")
        } catch {
            throw Failure.message("\"\(raw)\" isn't a key combo")
        }
    }

    private func modifiers(_ json: JSON?) throws -> [KeyModifier] {
        guard case .string(let raw)? = json, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var result: [KeyModifier] = []
        for part in raw.split(separator: "+") {
            guard let modifier = KeyModifier.aliases[part.trimmingCharacters(in: .whitespaces).lowercased()] else {
                throw Failure.message("\"\(part)\" isn't a modifier key")
            }
            result.append(modifier)
        }
        return result
    }

    // MARK: - Results

    private func observationResult(_ batch: ComputerUseBatchResult, toolCall: ToolCall) async throws -> ToolResult {
        guard let observation = batch.observations.first, let image = observation.image, let data = image.data else {
            let reason = batch.outcomes.first?.evidence ?? "no screenshot was taken"
            throw Failure.message(reason)
        }
        var lines = ["Observation \(observation.id)"]
        if let app = observation.target.app?.bundleID { lines[0] += " · \(app)" }
        lines[0] += " · \(image.geometry.imageSize.width)×\(image.geometry.imageSize.height) px"
        if let reminder = await ComputerUseToolProvider.reminder(for: session) { lines.append(reminder) }
        return ToolResult(
            success: true,
            parts: [
                .text(lines.joined(separator: "\n")),
                .image(ToolResultImage(
                    data: data,
                    mediaType: image.mediaType,
                    width: image.geometry.imageSize.width,
                    height: image.geometry.imageSize.height
                )),
            ],
            toolCallId: toolCall.id
        )
    }

    private func success(_ toolCall: ToolCall, _ text: String) async -> ToolResult {
        var lines = [text]
        if let reminder = await ComputerUseToolProvider.reminder(for: session) { lines.append(reminder) }
        return ToolResult(success: true, content: lines.joined(separator: "\n"), toolCallId: toolCall.id)
    }

    private func failure(_ toolCall: ToolCall, _ message: String) async -> ToolResult {
        if let id = toolCall.id { await failures.recordFailure(toolCallID: id) }
        return ToolResult(success: false, content: message, toolCallId: toolCall.id, error: message)
    }

    // MARK: - Arguments

    private static func fields(_ json: JSON) -> [String: JSON] {
        if case .object(let fields) = json { return fields }
        return [:]
    }

    private static func number(_ json: JSON?) -> Double? {
        switch json {
        case .integer(let value)?: return Double(value)
        case .double(let value)?: return value
        case .string(let value)?: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func numbers(_ json: JSON) -> [Double]? {
        guard case .array(let values) = json else { return nil }
        let numbers = values.compactMap { number($0) }
        return numbers.count == values.count ? numbers : nil
    }
}
