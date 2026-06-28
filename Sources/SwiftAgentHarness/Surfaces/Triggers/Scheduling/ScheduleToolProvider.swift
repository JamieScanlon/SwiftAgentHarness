import EasyJSON
import Foundation
import SwiftAgentKit

public struct ScheduleToolProvider: ToolProvider {
    private let scheduler: TriggerSchedulerService
    private let resolveHostTrigger: @Sendable () async -> HarnessTrigger?

    public init(
        scheduler: TriggerSchedulerService,
        resolveHostTrigger: @escaping @Sendable () async -> HarnessTrigger? = { nil }
    ) {
        self.scheduler = scheduler
        self.resolveHostTrigger = resolveHostTrigger
    }

    public var name: String { "ScheduleTools" }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "schedule_create",
                description: "Create a scheduled task (at, every, or cron).",
                parameters: [
                    .init(name: "scheduleKind", description: "at | every | cron", type: "string", required: true),
                    .init(name: "at", description: "ISO8601 for at", type: "string", required: false),
                    .init(name: "intervalMs", description: "Interval ms for every", type: "number", required: false),
                    .init(name: "cronExpr", description: "Cron expression", type: "string", required: false),
                    .init(name: "payloadKind", description: "systemEvent | agentTurn", type: "string", required: true),
                    .init(name: "payloadText", description: "Prompt or event text", type: "string", required: true),
                    .init(name: "recurring", description: "Whether task repeats", type: "boolean", required: true),
                    .init(name: "conversationID", description: "Optional threaded conversation UUID", type: "string", required: false),
                    .init(name: "rootId", description: "Optional workflow root trigger id", type: "string", required: false),
                    .init(name: "parentTriggerId", description: "Optional parent trigger id", type: "string", required: false),
                    .init(name: "correlationId", description: "Optional workflow correlation id", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: "schedule_list",
                description: "List scheduled tasks.",
                parameters: [],
                type: .function
            ),
            ToolDefinition(
                name: "schedule_delete",
                description: "Delete a scheduled task by id.",
                parameters: [.init(name: "id", description: "Task id", type: "string", required: true)],
                type: .function
            ),
            ToolDefinition(
                name: "schedule_fire_now",
                description: "Fire a scheduled task immediately.",
                parameters: [.init(name: "id", description: "Task id", type: "string", required: true)],
                type: .function
            ),
        ]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        do {
            let content: String
            switch toolCall.name {
            case "schedule_create":
                content = try await create(toolCall)
            case "schedule_list":
                content = try await list()
            case "schedule_delete":
                content = try await delete(toolCall)
            case "schedule_fire_now":
                content = try await fireNow(toolCall)
            default:
                return err(toolCall, "Unknown tool")
            }
            return ok(toolCall, content)
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
        let task = ScheduledTask(
            id: taskID,
            schedule: schedule,
            payloadKind: payloadKind,
            payloadText: payloadText,
            recurring: recurring,
            conversationID: extractString(from: toolCall.arguments, key: "conversationID"),
            correlation: correlation
        )
        let saved = try await scheduler.createTask(task)
        return "created id=\(saved.id)"
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
        let tasks = try await scheduler.listTasks()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tasks)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func delete(_ toolCall: ToolCall) async throws -> String {
        guard let id = extractString(from: toolCall.arguments, key: "id") else { return "id required" }
        let ok = try await scheduler.deleteTask(id: id)
        return ok ? "deleted" : "not_found"
    }

    private func fireNow(_ toolCall: ToolCall) async throws -> String {
        guard let id = extractString(from: toolCall.arguments, key: "id") else { return "id required" }
        let result = try await scheduler.fireNow(id: id)
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
