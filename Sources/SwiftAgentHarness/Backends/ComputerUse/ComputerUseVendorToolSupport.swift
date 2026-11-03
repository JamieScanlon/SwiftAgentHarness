import EasyJSON
import Foundation
import SwiftAgentKit

/// What OpenAI's and Gemini's computer tools share: every call ends with a fresh screenshot, the vendor's safety
/// signal rides on the call's first action, and a failure halts the rest of the model's batch.
struct ComputerUseVendorToolSupport: Sendable {
    let session: ComputerUseSession
    let failures: ComputerUseNativeFailures

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// How a call's actions went.
    struct Report: Sendable {
        /// Whether the action carrying the vendor's signals ran, which only happens once the user confirmed it.
        var acknowledged: Bool
        var failed: Bool
        /// One line per action that didn't simply succeed.
        var notes: [String]
        var screenshot: DisplayObservation?
        var reminder: String?
    }

    static func policyTags() -> [ToolPolicyTag] {
        [
            ToolPolicyTag(rawValue: ToolRegistryEntry.PolicyTag.haltsBatchOnFailure.rawValue),
            ComputerUseToolProvider.boundsOwnRunTimeTag,
            ToolRegistryResultFormattingPolicy.geometryBoundImagesPolicyTag(),
        ]
    }

    static func hints(for names: Set<String>) -> [String: ToolDescriptorHints] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly, policyTags: policyTags()))
        })
    }

    /// Runs `actions`, asking the user about `signals` before the first one, then takes the screenshot the vendor
    /// expects back. A call with signals but no actions still asks: a wait carries the question.
    func run(_ actions: [ComputerAction], signals: [ComputerUseSafetySignal], toolCallID: String?) async -> Report {
        var actions = actions
        if actions.isEmpty, !signals.isEmpty { actions = [.wait(milliseconds: 0)] }
        var report = Report(acknowledged: false, failed: false, notes: [])
        if !actions.isEmpty {
            let batch = await session.perform(actions, safetySignals: signals.isEmpty ? [:] : [0: signals])
            for outcome in batch.outcomes where outcome.effect != .confirmed && outcome.effect != .unverifiable {
                report.notes.append("Action \(outcome.action + 1) \(outcome.effect.rawValue)" + (outcome.evidence.map { ": \($0)" } ?? ""))
            }
            report.failed = batch.outcomes.contains { $0.effect == .refused || $0.effect == .notExecuted }
            if let first = batch.outcomes.first, !signals.isEmpty {
                report.acknowledged = first.effect.mayHaveBeenDelivered
            }
        }
        if report.failed, let toolCallID { await failures.recordFailure(toolCallID: toolCallID) }
        let observed = await session.perform([.observe(ObserveRequest(modes: [.pixels], scope: .display(nil)))])
        report.screenshot = observed.observations.first { $0.image?.data != nil }
        if report.screenshot == nil, let evidence = observed.outcomes.first?.evidence {
            report.notes.append("No screenshot: \(evidence)")
        }
        report.reminder = await ComputerUseToolProvider.reminder(for: session)
        return report
    }

    /// The latest screenshot's geometry, which the model's coordinates refer to.
    func latestGeometry() async throws -> (ObservationID, ScreenshotGeometry) {
        guard let screenshot = await session.latestScreenshot, let geometry = screenshot.image?.geometry else {
            throw Failure("take a screenshot first")
        }
        return (screenshot.id, geometry)
    }

    /// A point target from the model's coordinates, in the session's frozen coordinate mode.
    func point(_ x: JSON?, _ y: JSON?) async throws -> ActionTarget {
        guard let x = Self.number(x), let y = Self.number(y) else { throw Failure("x and y are required") }
        let (observation, geometry) = try await latestGeometry()
        do {
            return .point(try session.coordinateCodec.decode(x: x, y: y, geometry: geometry), observation: observation)
        } catch {
            throw Failure("[\(Int(x)), \(Int(y))] is outside the screenshot")
        }
    }

    /// Points per unit of the model's coordinates, horizontally and vertically.
    func unitScale() async throws -> (x: Double, y: Double) {
        let (_, geometry) = try await latestGeometry()
        let units: (Double, Double) = switch session.coordinateCodec.mode {
        case .normalized1000: (1_000, 1_000)
        default: (Double(geometry.imageSize.width), Double(geometry.imageSize.height))
        }
        return (geometry.capturedRect.width / max(units.0, 1), geometry.capturedRect.height / max(units.1, 1))
    }

    func result(_ toolCall: ToolCall, text: String, screenshot: DisplayObservation?) -> ToolResult {
        var parts: [ToolResultContentPart] = [.text(text)]
        if let screenshot, let image = screenshot.image, let data = image.data {
            parts.append(.image(ToolResultImage(
                data: data,
                mediaType: image.mediaType,
                width: image.geometry.imageSize.width,
                height: image.geometry.imageSize.height
            )))
        }
        return ToolResult(success: screenshot != nil, parts: parts, toolCallId: toolCall.id)
    }

    func failure(_ toolCall: ToolCall, _ message: String) async -> ToolResult {
        if let id = toolCall.id { await failures.recordFailure(toolCallID: id) }
        return ToolResult(success: false, content: message, toolCallId: toolCall.id, error: message)
    }

    // MARK: - Arguments

    static func fields(_ json: JSON?) -> [String: JSON] {
        if case .object(let fields)? = json { return fields }
        return [:]
    }

    static func number(_ json: JSON?) -> Double? {
        switch json {
        case .integer(let value)?: return Double(value)
        case .double(let value)?: return value
        case .string(let value)?: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func string(_ json: JSON?) -> String? {
        if case .string(let value)? = json { return value }
        return nil
    }

    static func bool(_ json: JSON?) -> Bool {
        switch json {
        case .boolean(let value)?: return value
        case .string(let value)?: return value.lowercased() == "true"
        default: return false
        }
    }

    /// A key combo from key names, as the vendors spell them: `["CTRL", "A"]` or `"Control+a"`.
    static func keyCombo(_ keys: [String]) throws -> KeyCombo {
        let parts = keys.flatMap { $0.split(separator: "+").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-") }
            .filter { !$0.isEmpty }
        do {
            return try KeyCombo(parsing: parts.joined(separator: "+"))
        } catch {
            throw Failure("\"\(keys.joined(separator: "+"))\" isn't a key combo")
        }
    }
}
