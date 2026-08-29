import EasyJSON
import Foundation
import SwiftAgentKit

/// The agent-facing webhook control plane.
///
/// One action-enum tool rather than seven names: four trigger kinds × seven ops would be 28 tools,
/// and a single name lets policy gate on `(tool, action)` in one place. A thin client — every
/// mutation goes through `TriggerRegistrationService`, which owns validation, the create-time
/// template scan, secret minting, trust clamping and creator stamping.
enum WebhookToolError: Error, Equatable {
    case nameRequired
    case notFound

    var code: String {
        switch self {
        case .nameRequired: return "name_required"
        case .notFound: return "not_found"
        }
    }
}

public struct WebhookToolProvider: ToolProvider {
    private let dataService: ScheduledTaskToolDataService

    init(dataService: ScheduledTaskToolDataService) {
        self.dataService = dataService
    }

    public var name: String { "WebhookTools" }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.webhook,
                description: "Manage inbound webhook subscriptions. `subscribe` returns a generated HMAC secret exactly once — give it to the user so they can configure it on the upstream service; it is never retrievable again. Prefer `pause` over `delete` when the user may want the route back.",
                parameters: [
                    .init(name: "action", description: "subscribe | list | get | update | pause | resume | delete | test", type: "string", required: true),
                    .init(name: "name", description: "Route name (lowercase letters, digits, - and _). Required for everything except list.", type: "string", required: false),
                    .init(name: "promptTemplate", description: "Prompt rendered against the payload. {dot.notation} substitutes fields; {__raw__} dumps the whole body. Default {__raw__}.", type: "string", required: false),
                    .init(name: "signatureScheme", description: "github-sha256 | gitlab-token | generic-hmac (default)", type: "string", required: false),
                    .init(name: "delivery", description: "agent (run the agent, default) | log | a channel id for pass-through", type: "string", required: false),
                    .init(name: "deliverOnly", description: "true renders the template and forwards it with no agent run — the cheap 'database changed, notify a channel' path. Requires delivery to be a real target, not agent or log.", type: "boolean", required: false),
                    .init(name: "deliveryWebhookURL", description: "http(s) URL for pass-through delivery", type: "string", required: false),
                    .init(name: "rateLimitPerMin", description: "Per-route request ceiling (per minute). Runtime-registered routes additionally share one global bucket set by the operator, so a high per-route value does not raise aggregate throughput.", type: "number", required: false),
                    .init(name: "enabled", description: "false to pause, true to resume", type: "boolean", required: false),
                    .init(name: "payload", description: "JSON string used by `test` to preview the rendered prompt without firing anything.", type: "string", required: false),
                ],
                type: .function
            ),
        ]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        var toolCall = toolCall
        if TriggerToolArgumentBridge.isSlashDispatch(toolCall.arguments) {
            guard let mapped = TriggerToolArgumentBridge.webhookArguments(from: toolCall.arguments) else {
                return err(toolCall, "usage: list | subscribe <name> [--prompt …] | get <name> | update <name> … | pause <name> | resume <name> | delete <name> | test <name> --payload '{…}'")
            }
            toolCall = ToolCall(name: toolCall.name, arguments: mapped, id: toolCall.id)
        }
        do {
            guard let action = Self.string(toolCall.arguments, "action") else {
                return err(toolCall, "action required")
            }
            let content: String
            switch action {
            case "subscribe": content = try await subscribe(toolCall)
            case "list": content = try await list()
            case "get": content = try await get(toolCall)
            case "update": content = try await update(toolCall)
            case "pause": content = try await setEnabled(toolCall, enabled: false)
            case "resume": content = try await setEnabled(toolCall, enabled: true)
            case "delete": content = try await delete(toolCall)
            case "test": content = try await test(toolCall)
            default: return err(toolCall, "unknown action \(action)")
            }
            return ok(toolCall, content)
        } catch let error as WebhookToolError {
            return err(toolCall, error.code)
        } catch let error as TriggerRegistrationError {
            return err(toolCall, error.code)
        } catch ScheduledTaskAccessError.notFound {
            return err(toolCall, "not_found")
        } catch {
            return err(toolCall, String(describing: error))
        }
    }

    // MARK: - Actions

    private func subscribe(_ toolCall: ToolCall) async throws -> String {
        guard let name = Self.string(toolCall.arguments, "name") else { throw WebhookToolError.nameRequired }
        let spec = WebhookRegistrationSpec(
            name: name,
            signatureScheme: Self.string(toolCall.arguments, "signatureScheme")
                .flatMap(WebhookSignatureScheme.init(rawValue:)) ?? .genericHMAC,
            promptTemplate: Self.string(toolCall.arguments, "promptTemplate") ?? "{__raw__}",
            delivery: Self.string(toolCall.arguments, "delivery") ?? "agent",
            deliverOnly: Self.boolean(toolCall.arguments, "deliverOnly") ?? false,
            deliveryWebhookURL: Self.string(toolCall.arguments, "deliveryWebhookURL"),
            rateLimitPerMin: Self.boundedInt(toolCall.arguments, "rateLimitPerMin")
        )
        let result = try await dataService.subscribeWebhook(spec)
        guard let secret = result.generatedSecret else {
            return "subscribed name=\(result.route.name) path=/webhook/\(result.route.name) (existing secret retained)"
        }
        return """
            subscribed name=\(result.route.name)
            path=/webhook/\(result.route.name)
            scheme=\(result.route.signatureScheme.rawValue)
            secret=\(secret)
            Give the secret to the user now — it is not retrievable again.
            """
    }

    private func list() async throws -> String {
        let routes = try await dataService.listWebhooks()
        guard !routes.isEmpty else { return "no webhook routes" }
        return routes.map { route in
            "\(route.name) source=\(route.source.rawValue) enabled=\(route.enabled) delivery=\(route.delivery) rate=\(route.rateLimitPerMin)/min"
        }.joined(separator: "\n")
    }

    private func get(_ toolCall: ToolCall) async throws -> String {
        guard let name = Self.string(toolCall.arguments, "name") else { throw WebhookToolError.nameRequired }
        guard let route = try await dataService.webhookRoute(named: name) else { throw WebhookToolError.notFound }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(route)
        return String(data: data, encoding: .utf8) ?? "not_found"
    }

    private func update(_ toolCall: ToolCall) async throws -> String {
        guard let name = Self.string(toolCall.arguments, "name") else { throw WebhookToolError.nameRequired }
        let arguments = toolCall.arguments
        let route = try await dataService.updateWebhook(name: name) { spec in
            if let template = Self.string(arguments, "promptTemplate") { spec.promptTemplate = template }
            if let raw = Self.string(arguments, "signatureScheme"), let scheme = WebhookSignatureScheme(rawValue: raw) {
                spec.signatureScheme = scheme
            }
            if let delivery = Self.string(arguments, "delivery") { spec.delivery = delivery }
            if let deliverOnly = Self.boolean(arguments, "deliverOnly") { spec.deliverOnly = deliverOnly }
            if let url = Self.string(arguments, "deliveryWebhookURL") { spec.deliveryWebhookURL = url }
            if let rate = Self.boundedInt(arguments, "rateLimitPerMin") { spec.rateLimitPerMin = rate }
            if let enabled = Self.boolean(arguments, "enabled") { spec.enabled = enabled }
        }
        return "updated name=\(route.name) enabled=\(route.enabled)"
    }

    private func setEnabled(_ toolCall: ToolCall, enabled: Bool) async throws -> String {
        guard let name = Self.string(toolCall.arguments, "name") else { throw WebhookToolError.nameRequired }
        let route = try await dataService.setWebhookEnabled(name: name, enabled: enabled)
        return "\(enabled ? "resumed" : "paused") name=\(route.name)"
    }

    private func delete(_ toolCall: ToolCall) async throws -> String {
        guard let name = Self.string(toolCall.arguments, "name") else { throw WebhookToolError.nameRequired }
        guard try await dataService.deleteWebhook(name: name) else { throw WebhookToolError.notFound }
        return "deleted name=\(name)"
    }

    /// Dry run: render the route's template against a payload without firing anything. The reference
    /// debugging primitive — it answers "is my template right?" without contacting the source or
    /// spending a turn.
    private func test(_ toolCall: ToolCall) async throws -> String {
        guard let name = Self.string(toolCall.arguments, "name") else { throw WebhookToolError.nameRequired }
        guard let route = try await dataService.webhookRoute(named: name) else { throw WebhookToolError.notFound }
        let raw = Self.string(toolCall.arguments, "payload") ?? "{}"
        let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? ["__raw__": raw]
        let rendered = WebhookPromptTemplate.render(template: route.promptTemplate, payload: parsed)
        return """
            route=\(route.name) enabled=\(route.enabled) deliverOnly=\(route.deliverOnly)
            --- rendered prompt (not fired) ---
            \(rendered)
            """
    }

    // MARK: - Argument access

    private static func string(_ arguments: JSON, _ key: String) -> String? {
        guard case .object(let dict) = arguments, let value = dict[key], case .string(let text) = value else { return nil }
        return text.isEmpty ? nil : text
    }

    private static func boolean(_ arguments: JSON, _ key: String) -> Bool? {
        guard case .object(let dict) = arguments, let value = dict[key], case .boolean(let flag) = value else { return nil }
        return flag
    }

    /// `Int(_: Double)` traps on NaN and on anything past `Int.max`, and these values come straight
    /// from a model. Clamp rather than convert.
    private static func boundedInt(_ arguments: JSON, _ key: String, max upper: Int = 100_000) -> Int? {
        guard let raw = number(arguments, key), raw.isFinite else { return nil }
        return Int(Swift.max(1, Swift.min(Double(upper), raw.rounded())))
    }

    private static func number(_ arguments: JSON, _ key: String) -> Double? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        switch value {
        case .double(let double): return double
        case .integer(let integer): return Double(integer)
        default: return nil
        }
    }

    private func ok(_ toolCall: ToolCall, _ content: String) -> ToolResult {
        ToolResult(success: true, content: content, metadata: .object(["source": .string("webhook_tools")]), toolCallId: toolCall.id)
    }

    private func err(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(success: false, content: "", metadata: .object(["source": .string("webhook_tools")]), toolCallId: toolCall.id, error: message)
    }
}
