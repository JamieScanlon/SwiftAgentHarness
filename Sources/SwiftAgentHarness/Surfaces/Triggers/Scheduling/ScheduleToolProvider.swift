import EasyJSON
import Foundation
import SwiftAgentKit

public struct ScheduleToolProvider: ToolProvider {
    private let dataService: ScheduledTaskToolDataService
    private let resolveHostTrigger: @Sendable () async -> HarnessTrigger?

    init(
        dataService: ScheduledTaskToolDataService,
        resolveHostTrigger: @escaping @Sendable () async -> HarnessTrigger? = { nil }
    ) {
        self.dataService = dataService
        self.resolveHostTrigger = resolveHostTrigger
    }

    public var name: String { "ScheduleTools" }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.scheduleCreate,
                description: "Create a scheduled task (at, every, or cron) that runs later with no human present. Use this for reminders, follow-ups and recurring checks. Do not emulate scheduling with sleep loops or background processes. Defaults to the caller conversation, so the answer comes back where the user asked.",
                parameters: [
                    .init(name: "scheduleKind", description: "at | every | cron", type: "string", required: true),
                    .init(name: "at", description: "ISO8601 for at", type: "string", required: false),
                    .init(name: "intervalMs", description: "Interval ms for every", type: "number", required: false),
                    .init(name: "cronExpr", description: "Cron expression", type: "string", required: false),
                    .init(name: "timezone", description: "IANA timezone the cron wall-clock is read in, e.g. Europe/Berlin. Defaults to the harness host's zone, captured now rather than resolved at fire time. Only meaningful for cron. An unrecognised identifier is rejected rather than defaulted.", type: "string", required: false),
                    .init(name: "payloadKind", description: "systemEvent | agentTurn", type: "string", required: true),
                    .init(name: "payloadText", description: "Prompt or event text", type: "string", required: true),
                    .init(name: "recurring", description: "Whether task repeats", type: "boolean", required: true),
                    .init(name: "conversationID", description: "Optional threaded conversation UUID (defaults to caller)", type: "string", required: false),
                    .init(name: "title", description: "Short human-readable label shown in schedule_list", type: "string", required: false),
                    .init(name: "delivery", description: "none | announce | webhook. Default announce — the answer is delivered back to the chat the task was created from. Use none only for tasks whose output nobody needs to see.", type: "string", required: false),
                    .init(name: "deliveryWebhookURL", description: "Required when delivery=webhook. http(s) URL to POST the result to.", type: "string", required: false),
                    .init(name: "routingMode", description: "isolated | threaded | delegated. Omit to infer: threaded into the target conversation, or isolated when there is none. Choose isolated only when the run must NOT see or touch the conversation's history.", type: "string", required: false),
                    .init(name: "durable", description: "false (default for agent-created tasks) = lives in memory and dies with this process. true = persists across restarts. Pass true only when the user gave a standing instruction like 'every day from now on'.", type: "boolean", required: false),
                    .init(name: "rootId", description: "Optional workflow root trigger id", type: "string", required: false),
                    .init(name: "parentTriggerId", description: "Optional parent trigger id", type: "string", required: false),
                    .init(name: "correlationId", description: "Optional workflow correlation id", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.scheduleList,
                description: "List scheduled tasks accessible from the caller conversation.",
                parameters: [],
                type: .function
            ),
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.scheduleDelete,
                description: "Delete a scheduled task by id.",
                parameters: [.init(name: "id", description: "Task id", type: "string", required: true)],
                type: .function
            ),
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.scheduleFireNow,
                description: "Fire a scheduled task immediately. Runs through the same validation and delivery path as a scheduled fire — it is a convenience, not a bypass.",
                parameters: [.init(name: "id", description: "Task id", type: "string", required: true)],
                type: .function
            ),
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.scheduleUpdate,
                description: "Change an existing scheduled task in place. Only the fields you pass are changed; the task keeps its id, history and next-fire anchor. The new prompt and schedule are re-validated exactly as on create.",
                parameters: [
                    .init(name: "id", description: "Task id", type: "string", required: true),
                    .init(name: "payloadText", description: "Replacement prompt or event text", type: "string", required: false),
                    .init(name: "title", description: "Replacement label", type: "string", required: false),
                    .init(name: "cronExpr", description: "Replacement cron expression", type: "string", required: false),
                    .init(name: "timezone", description: "Replacement IANA timezone for a cron schedule.", type: "string", required: false),
                    .init(name: "at", description: "Replacement ISO8601 one-shot time", type: "string", required: false),
                    .init(name: "intervalMs", description: "Replacement interval in ms", type: "number", required: false),
                    .init(name: "delivery", description: "none | announce | webhook", type: "string", required: false),
                    .init(name: "deliveryWebhookURL", description: "Replacement webhook URL", type: "string", required: false),
                    .init(name: "routingMode", description: "isolated | threaded | delegated", type: "string", required: false),
                    .init(name: "recurring", description: "Whether the task repeats. Forced false when switching to a one-shot 'at' schedule.", type: "boolean", required: false),
                    .init(name: "enabled", description: "false to pause, true to resume", type: "boolean", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.schedulePause,
                description: "Pause a scheduled task without deleting it. Prefer this over schedule_delete when the user may want it back — the task keeps its history and next-fire anchor.",
                parameters: [.init(name: "id", description: "Task id", type: "string", required: true)],
                type: .function
            ),
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.scheduleResume,
                description: "Resume a paused scheduled task.",
                parameters: [.init(name: "id", description: "Task id", type: "string", required: true)],
                type: .function
            ),
        ]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        // A slash dispatch arrives as one raw line; rewrite it into the arguments the model would
        // have produced so there is exactly one handler per operation, not one per surface.
        var toolCall = toolCall
        if TriggerToolArgumentBridge.isSlashDispatch(toolCall.arguments) {
            guard let mapped = TriggerToolArgumentBridge.scheduleCall(from: toolCall.arguments) else {
                return err(toolCall, "usage: list | create --cron <expr> <prompt> | update <id> … | pause <id> | resume <id> | rm <id> | run <id>")
            }
            toolCall = ToolCall(name: mapped.toolName, arguments: mapped.arguments, id: toolCall.id)
        }
        do {
            let content: String
            switch toolCall.name {
            case ToolControlPlaneClassification.TriggerTools.scheduleCreate:
                content = try await create(toolCall)
            case ToolControlPlaneClassification.TriggerTools.scheduleList:
                content = try await list()
            case ToolControlPlaneClassification.TriggerTools.scheduleDelete:
                content = try await delete(toolCall)
            case ToolControlPlaneClassification.TriggerTools.scheduleFireNow:
                content = try await fireNow(toolCall)
            case ToolControlPlaneClassification.TriggerTools.scheduleUpdate:
                content = try await update(toolCall)
            case ToolControlPlaneClassification.TriggerTools.schedulePause:
                content = try await setEnabled(toolCall, enabled: false)
            case ToolControlPlaneClassification.TriggerTools.scheduleResume:
                content = try await setEnabled(toolCall, enabled: true)
            default:
                return err(toolCall, "Unknown tool")
            }
            return ok(toolCall, content)
        } catch ScheduledTaskAccessError.notFound {
            return err(toolCall, "not_found")
        } catch {
            return err(toolCall, String(describing: error))
        }
    }

    private func create(_ toolCall: ToolCall) async throws -> String {
        let scheduleKindRaw = extractString(from: toolCall.arguments, key: "scheduleKind") ?? ""
        let payloadKindRaw = extractString(from: toolCall.arguments, key: "payloadKind") ?? ""
        let payloadText = extractString(from: toolCall.arguments, key: "payloadText") ?? ""
        let recurring = extractBool(from: toolCall.arguments, key: "recurring") ?? false
        let scheduleKind = ScheduledTaskScheduleKind(rawValue: scheduleKindRaw) ?? .at
        var schedule = ScheduledTaskSchedule(kind: scheduleKind)
        switch scheduleKind {
        case .at:
            schedule.at = extractString(from: toolCall.arguments, key: "at")
        case .every:
            if let n = extractDouble(from: toolCall.arguments, key: "intervalMs") {
                schedule.intervalMs = Int64(n)
            }
        case .cron:
            schedule.expr = extractString(from: toolCall.arguments, key: "cronExpr")
        }
        let payloadKind = ScheduledTaskPayloadKind(rawValue: payloadKindRaw) ?? .agentTurn
        let taskID = UUID().uuidString
        let correlation = await resolveTaskCorrelation(
            arguments: toolCall.arguments,
            taskID: taskID
        )
        // A registration *spec*, not a task: trust, durability, `permanent`, and creator stamping
        // are derived from the caller's authority inside the registration service and are not
        // expressible here. That absence is the trust ceiling — enforced by the schema rather than
        // by a runtime check a confused deputy could route around.
        let spec = ScheduleRegistrationSpec(
            id: taskID,
            schedule: schedule,
            payloadKind: payloadKind,
            payloadText: payloadText,
            delivery: extractString(from: toolCall.arguments, key: "delivery")
                .flatMap(ScheduledTaskDelivery.init(rawValue:)) ?? .announce,
            deliveryWebhookURL: extractString(from: toolCall.arguments, key: "deliveryWebhookURL"),
            recurring: recurring,
            conversationID: extractString(from: toolCall.arguments, key: "conversationID"),
            title: extractString(from: toolCall.arguments, key: "title"),
            routingMode: extractString(from: toolCall.arguments, key: "routingMode")
                .flatMap(TriggerRoutingMode.init(rawValue:)),
            correlation: correlation,
            durable: extractBool(from: toolCall.arguments, key: "durable"),
            timezone: extractString(from: toolCall.arguments, key: "timezone")
        )
        let saved = try await dataService.createTask(spec)
        return "created id=\(saved.id) delivery=\(saved.delivery.rawValue) durable=\(saved.durable)"
    }

    private func update(_ toolCall: ToolCall) async throws -> String {
        guard let id = extractString(from: toolCall.arguments, key: "id") else { return "id required" }
        let arguments = toolCall.arguments
        let saved = try await dataService.updateTask(id: id) { spec in
            if let text = Self.string(arguments, "payloadText") { spec.payloadText = text }
            if let title = Self.string(arguments, "title") { spec.title = title }
            if let raw = Self.string(arguments, "delivery"), let delivery = ScheduledTaskDelivery(rawValue: raw) {
                spec.delivery = delivery
            }
            if let url = Self.string(arguments, "deliveryWebhookURL") { spec.deliveryWebhookURL = url }
            if let raw = Self.string(arguments, "routingMode"), let mode = TriggerRoutingMode(rawValue: raw) {
                spec.routingMode = mode
            }
            if let cron = Self.string(arguments, "cronExpr") {
                spec.schedule = ScheduledTaskSchedule(kind: .cron, expr: cron)
            } else if let at = Self.string(arguments, "at") {
                spec.schedule = ScheduledTaskSchedule(kind: .at, at: at)
                // A one-shot timestamp cannot recur: `nextFireDate` returns nil once it has fired,
                // so leaving `recurring` set would strand the row inert until age-out.
                spec.recurring = Self.boolean(arguments, "recurring") ?? false
            } else if let interval = Self.number(arguments, "intervalMs") {
                spec.schedule = ScheduledTaskSchedule(kind: .every, intervalMs: Int64(interval))
            }
            if let recurring = Self.boolean(arguments, "recurring") { spec.recurring = recurring }
            if let enabled = Self.boolean(arguments, "enabled") { spec.enabled = enabled }
            if let timezone = Self.string(arguments, "timezone") { spec.timezone = timezone }
        }
        return "updated id=\(saved.id) enabled=\(saved.enabled)"
    }

    private func setEnabled(_ toolCall: ToolCall, enabled: Bool) async throws -> String {
        guard let id = extractString(from: toolCall.arguments, key: "id") else { return "id required" }
        let saved = try await dataService.setTaskEnabled(id: id, enabled: enabled)
        return "\(enabled ? "resumed" : "paused") id=\(saved.id)"
    }

    // Static accessors so the update closure does not capture `self`.
    private static func string(_ arguments: JSON, _ key: String) -> String? {
        guard case .object(let dict) = arguments, case .string(let value) = dict[key] else { return nil }
        return value.isEmpty ? nil : value
    }

    private static func boolean(_ arguments: JSON, _ key: String) -> Bool? {
        guard case .object(let dict) = arguments, case .boolean(let value) = dict[key] else { return nil }
        return value
    }

    private static func number(_ arguments: JSON, _ key: String) -> Double? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        switch value {
        case .double(let double): return double
        case .integer(let integer): return Double(integer)
        default: return nil
        }
    }

    private func resolveTaskCorrelation(arguments: JSON, taskID: String) async -> TriggerCorrelation {
        let explicitRoot = extractString(from: arguments, key: "rootId")
        let explicitParent = extractString(from: arguments, key: "parentTriggerId")
        let explicitCorrelation = extractString(from: arguments, key: "correlationId")
        if let explicit = TriggerCorrelation.explicit(
            rootId: explicitRoot,
            parentTriggerId: explicitParent,
            correlationId: explicitCorrelation,
            fallbackTriggerID: taskID
        ) {
            return explicit
        }
        if let hostTrigger = await resolveHostTrigger() {
            return .child(parent: hostTrigger, followUpKind: "scheduled")
        }
        return .root(triggerID: taskID)
    }

    private func list() async throws -> String {
        let tasks = try await dataService.listAccessibleTasks()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tasks)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func delete(_ toolCall: ToolCall) async throws -> String {
        guard let id = extractString(from: toolCall.arguments, key: "id") else { return "id required" }
        let ok = try await dataService.deleteTask(id: id)
        return ok ? "deleted" : "not_found"
    }

    private func fireNow(_ toolCall: ToolCall) async throws -> String {
        guard let id = extractString(from: toolCall.arguments, key: "id") else { return "id required" }
        let result = try await dataService.fireNow(id: id)
        return "decision=\(result.decision.rawValue) session=\(result.sessionID?.uuidString ?? "nil")"
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }

    private func extractBool(from arguments: JSON, key: String) -> Bool? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        if case .boolean(let b) = value { return b }
        return nil
    }

    private func extractDouble(from arguments: JSON, key: String) -> Double? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        switch value {
        case .integer(let i):
            return Double(i)
        case .double(let d):
            return d
        default:
            return nil
        }
    }

    private func ok(_ toolCall: ToolCall, _ content: String) -> ToolResult {
        ToolResult(success: true, content: content, metadata: .object(["source": .string("schedule_tools")]), toolCallId: toolCall.id)
    }

    private func err(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(success: false, content: "", metadata: .object(["source": .string("schedule_tools")]), toolCallId: toolCall.id, error: message)
    }
}
