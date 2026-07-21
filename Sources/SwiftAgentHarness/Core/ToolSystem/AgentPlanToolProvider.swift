//
//  Local tools: create_plan, edit_plan, update_plan_task, add_plan_task, delete_plan_task, add_plan_note, get_plan
//

import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

// MARK: - Models

public enum PlanTaskStatus: String, Codable, Sendable, Equatable {
    case notStarted = "not-started"
    case inProgress = "in-progress"
    case complete = "complete"
    case blocked = "blocked"
}

public struct PlanTaskInput: Codable, Sendable, Equatable {
    public let id: UUID
    public let description: String
    public let status: PlanTaskStatus

    public init(id: UUID, description: String, status: PlanTaskStatus) {
        self.id = id
        self.description = description
        self.status = status
    }
}

// MARK: - Provider

/// Local tools for reading and writing `plan.md` under the conversation directory.
public struct AgentPlanToolProvider: ToolProvider, ToolDescriptorHinting {

    public static let createPlanToolName = "create_plan"
    public static let editPlanToolName = "edit_plan"
    public static let updatePlanTaskToolName = "update_plan_task"
    public static let addPlanTaskToolName = "add_plan_task"
    public static let deletePlanTaskToolName = "delete_plan_task"
    public static let addPlanNoteToolName = "add_plan_note"
    public static let getPlanToolName = "get_plan"
    public static let declareAgentBuildCompleteToolName = "declare_agent_build_complete"

    private let dataProvider: ConversationsDataProviding
    private let resolveConversationID: @Sendable () async -> UUID?
    private let logger: Logger?

    public var name: String { "AgentPlan" }
    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.createPlanToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.editPlanToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.updatePlanTaskToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.addPlanTaskToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.deletePlanTaskToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.addPlanNoteToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.getPlanToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.declareAgentBuildCompleteToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
        ]
    }

    public init(
        dataProvider: ConversationsDataProviding,
        resolveConversationID: @escaping @Sendable () async -> UUID? = {
            ConversationScope.resolvedConversationID()
        },
        logger: Logger? = nil
    ) {
        self.dataProvider = dataProvider
        self.resolveConversationID = resolveConversationID
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "AgentPlanToolProvider")
        )
    }

    public func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        guard definition.name == Self.getPlanToolName else { return [] }
        return [ToolRegistryResultFormattingPolicy.exactContentObservationPolicyTag()]
    }

    public func availableTools() async -> [ToolDefinition] {
        let tasksParamDescription =
            "JSON array of objects: [{\"id\":\"<uuid>\",\"description\":\"<string>\",\"status\":\"not-started|in-progress|complete|blocked\"}, ...]"

        return [
            ToolDefinition(
                name: Self.createPlanToolName,
                description:
                    "Create plan.md for the active conversation. Writes the conversation-scoped plan.md with # Plan, ## Goal, ## Notes, and ## Tasks (one line per task: [marker] id:<uuid> - description). Use this instead of shell file editing.",
                parameters: [
                    .init(name: "tasks", description: tasksParamDescription, type: "string", required: true),
                    .init(
                        name: "overview",
                        description: "Optional markdown/plain text for the # Plan section body (below the heading).",
                        type: "string",
                        required: false
                    ),
                    .init(name: "goal", description: "Optional text for the ## Goal section body.", type: "string", required: false),
                    .init(name: "notes", description: "Optional text for the ## Notes section (context, paths, doc links—avoid raw secrets).", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.editPlanToolName,
                description:
                    "Replace the entire plan.md for a conversation (same shape as create_plan). Use for full rewrites. If notes is omitted, existing ## Notes content is preserved.",
                parameters: [
                    .init(name: "tasks", description: tasksParamDescription, type: "string", required: true),
                    .init(name: "overview", description: "Optional # Plan section body.", type: "string", required: false),
                    .init(name: "goal", description: "Optional ## Goal section body.", type: "string", required: false),
                    .init(name: "notes", description: "Optional ## Notes section body. Omit to keep existing notes when editing.", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.updatePlanTaskToolName,
                description:
                    "Update a single task line in plan.md by task id (must exist). Optionally change status and/or description.",
                parameters: [
                    .init(name: "task_id", description: "Task UUID (must match id: in the plan file)", type: "string", required: true),
                    .init(
                        name: "status",
                        description: "Optional new status: not-started, in-progress, complete, blocked",
                        type: "string",
                        required: false
                    ),
                    .init(name: "description", description: "Optional new task description (text after \"- \")", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.addPlanTaskToolName,
                description:
                    "Add one new task to ## Tasks in plan.md (parses existing sections, then rewrites the file). Requires plan.md. task_id must be unique.",
                parameters: [
                    .init(name: "task_id", description: "UUID for the new task (must not already exist in plan.md)", type: "string", required: true),
                    .init(name: "description", description: "Task description (text after \"- \" on the line)", type: "string", required: true),
                    .init(
                        name: "status",
                        description: "not-started, in-progress, complete, or blocked",
                        type: "string",
                        required: true
                    ),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.deletePlanTaskToolName,
                description:
                    "Remove a single task line from plan.md by task id. Requires plan.md to exist.",
                parameters: [
                    .init(name: "task_id", description: "Task UUID to remove (must exist in plan.md)", type: "string", required: true),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.addPlanNoteToolName,
                description:
                    "Append markdown or plain text to the ## Notes section of plan.md (durable context discovered during implementation: paths, doc URLs, env var names, etc.). Requires plan.md. Do not store raw secrets or token values.",
                parameters: [
                    .init(name: "note", description: "Content to append to ## Notes (separated from prior content by a blank line).", type: "string", required: true),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.getPlanToolName,
                description: "Read plan.md for the active conversation and return its markdown. Returns a message if no plan exists yet.",
                parameters: [
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.declareAgentBuildCompleteToolName,
                description:
                    "Declare the agent build phase complete. Succeeds only when plan.md exists, has at least one task line, every task is complete ([x]), and no task is blocked ([!]). Fails if work remains—update the plan first.",
                parameters: [
                ],
                type: .function
            ),
        ]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        switch toolCall.name {
        case Self.createPlanToolName:
            return try await executeCreatePlan(toolCall, replaceExisting: false)
        case Self.editPlanToolName:
            return try await executeCreatePlan(toolCall, replaceExisting: true)
        case Self.updatePlanTaskToolName:
            return try await executeUpdatePlanTask(toolCall)
        case Self.addPlanTaskToolName:
            return try await executeAddPlanTask(toolCall)
        case Self.deletePlanTaskToolName:
            return try await executeDeletePlanTask(toolCall)
        case Self.addPlanNoteToolName:
            return try await executeAddPlanNote(toolCall)
        case Self.getPlanToolName:
            return try await executeGetPlan(toolCall)
        case Self.declareAgentBuildCompleteToolName:
            return try await executeDeclareAgentBuildComplete(toolCall)
        default:
            throw Error.unknownTool(toolCall.name)
        }
    }

    private func executeCreatePlan(_ toolCall: ToolCall, replaceExisting: Bool) async throws -> ToolResult {
        let bound = await bindConversationOrError(for: toolCall)
        if let error = bound.error {
            return error
        }
        let conversationId = bound.id
        let conversationIdString = bound.idString
        guard let tasksJSON = extractString(from: toolCall.arguments, key: "tasks") else {
            throw Error.missingParameter("tasks")
        }


        let tasks: [PlanTaskInput]
        do {
            tasks = Self.enforcingAtMostOneInProgress(try decodeTasksJSON(tasksJSON))
        } catch {
            return toolError(toolCall, "Invalid tasks JSON: \(error.localizedDescription)")
        }

        let overview = extractString(from: toolCall.arguments, key: "overview")
        let goal = extractString(from: toolCall.arguments, key: "goal")
        let url = AgentPlanStore.planURL(for: conversationId)

        let notesForRender: String?
        if let n = extractString(from: toolCall.arguments, key: "notes") {
            notesForRender = n
        } else if replaceExisting,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let existing = String(data: data, encoding: .utf8) {
            let doc = PlanMarkdownParser.parseDocument(existing)
            notesForRender = doc.notes.isEmpty ? nil : doc.notes
        } else {
            notesForRender = nil
        }

        if !replaceExisting, FileManager.default.fileExists(atPath: url.path) {
            return toolError(toolCall, "plan.md already exists; use edit_plan to replace it.")
        }

        try AgentPlanStore.ensureConversationDirectory(for: conversationId)
        let body = Self.renderPlanMarkdown(overview: overview, goal: goal, notes: notesForRender, tasks: tasks)
        try body.write(to: url, atomically: true, encoding: .utf8)

        logger?.info(
            replaceExisting ? "edit_plan wrote plan.md" : "create_plan wrote plan.md",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIdString)),
                ("taskCount", .stringConvertible(tasks.count)),
                ("toolCallId", .string(toolCall.id ?? "nil"))
            )
        )

        return planToolSuccess(
            toolCall,
            content: replaceExisting ? "Updated plan.md (\(tasks.count) tasks)." : "Created plan.md (\(tasks.count) tasks).",
            baseMetadata: [
                "source": .string("agent_plan_tool"),
                "action": .string(replaceExisting ? "edit_plan" : "create_plan"),
                "conversationId": .string(conversationIdString),
                "taskCount": .integer(tasks.count),
            ],
            planMarkdown: body
        )
    }

    private func executeUpdatePlanTask(_ toolCall: ToolCall) async throws -> ToolResult {
        let bound = await bindConversationOrError(for: toolCall)
        if let error = bound.error {
            return error
        }
        let conversationId = bound.id
        let conversationIdString = bound.idString
        guard let taskIdString = extractString(from: toolCall.arguments, key: "task_id") else {
            throw Error.missingParameter("task_id")
        }
        guard let taskId = UUID(uuidString: taskIdString) else {
            return toolError(toolCall, "Invalid task_id")
        }


        let url = AgentPlanStore.planURL(for: conversationId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var text = String(data: data, encoding: .utf8)
        else {
            return toolError(toolCall, "No plan.md for this conversation.")
        }

        let statusStr = extractString(from: toolCall.arguments, key: "status")
        let newDescription = extractString(from: toolCall.arguments, key: "description")

        let newStatus: PlanTaskStatus?
        if let statusStr {
            guard let s = PlanTaskStatus(rawValue: statusStr) else {
                return toolError(toolCall, "Invalid status; use not-started, in-progress, complete, or blocked.")
            }
            newStatus = s
        } else {
            newStatus = nil
        }

        if newStatus == nil, newDescription == nil {
            return toolError(toolCall, "Provide at least one of status or description.")
        }

        do {
            text = try Self.updateTaskLine(in: text, taskId: taskId, newStatus: newStatus, newDescription: newDescription)
        } catch AgentPlanToolError.taskNotFound {
            return toolError(toolCall, "Task id not found in plan.md: \(taskIdString)")
        }

        try text.write(to: url, atomically: true, encoding: .utf8)

        logger?.info(
            "update_plan_task",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIdString)),
                ("taskId", .string(taskIdString)),
                ("toolCallId", .string(toolCall.id ?? "nil"))
            )
        )

        return planToolSuccess(
            toolCall,
            content: "Updated task \(taskIdString) in plan.md.",
            baseMetadata: [
                "source": .string("agent_plan_tool"),
                "action": .string("update_plan_task"),
                "conversationId": .string(conversationIdString),
                "taskId": .string(taskIdString),
            ],
            planMarkdown: text
        )
    }

    private func executeAddPlanTask(_ toolCall: ToolCall) async throws -> ToolResult {
        let bound = await bindConversationOrError(for: toolCall)
        if let error = bound.error {
            return error
        }
        let conversationId = bound.id
        let conversationIdString = bound.idString
        guard let taskIdString = extractString(from: toolCall.arguments, key: "task_id") else {
            throw Error.missingParameter("task_id")
        }
        guard let taskId = UUID(uuidString: taskIdString) else {
            return toolError(toolCall, "Invalid task_id")
        }
        guard let description = extractString(from: toolCall.arguments, key: "description") else {
            throw Error.missingParameter("description")
        }
        guard let statusStr = extractString(from: toolCall.arguments, key: "status") else {
            throw Error.missingParameter("status")
        }
        guard let status = PlanTaskStatus(rawValue: statusStr) else {
            return toolError(toolCall, "Invalid status; use not-started, in-progress, complete, or blocked.")
        }


        let url = AgentPlanStore.planURL(for: conversationId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return toolError(toolCall, "No plan.md for this conversation.")
        }

        let task = PlanTaskInput(id: taskId, description: description, status: status)
        let newText: String
        do {
            newText = try Self.addingTask(task, to: text)
        } catch AgentPlanToolError.duplicateTaskId {
            return toolError(toolCall, "Task id already exists in plan.md: \(taskIdString)")
        }

        try newText.write(to: url, atomically: true, encoding: .utf8)

        logger?.info(
            "add_plan_task",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIdString)),
                ("taskId", .string(taskIdString)),
                ("toolCallId", .string(toolCall.id ?? "nil"))
            )
        )

        return planToolSuccess(
            toolCall,
            content: "Added task \(taskIdString) to plan.md.",
            baseMetadata: [
                "source": .string("agent_plan_tool"),
                "action": .string("add_plan_task"),
                "conversationId": .string(conversationIdString),
                "taskId": .string(taskIdString),
            ],
            planMarkdown: newText
        )
    }

    private func executeDeletePlanTask(_ toolCall: ToolCall) async throws -> ToolResult {
        let bound = await bindConversationOrError(for: toolCall)
        if let error = bound.error {
            return error
        }
        let conversationId = bound.id
        let conversationIdString = bound.idString
        guard let taskIdString = extractString(from: toolCall.arguments, key: "task_id") else {
            throw Error.missingParameter("task_id")
        }
        guard let taskId = UUID(uuidString: taskIdString) else {
            return toolError(toolCall, "Invalid task_id")
        }


        let url = AgentPlanStore.planURL(for: conversationId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return toolError(toolCall, "No plan.md for this conversation.")
        }

        let newText: String
        do {
            newText = try Self.removingTask(id: taskId, from: text)
        } catch AgentPlanToolError.taskNotFound {
            return toolError(toolCall, "Task id not found in plan.md: \(taskIdString)")
        }

        try newText.write(to: url, atomically: true, encoding: .utf8)

        logger?.info(
            "delete_plan_task",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIdString)),
                ("taskId", .string(taskIdString)),
                ("toolCallId", .string(toolCall.id ?? "nil"))
            )
        )

        return planToolSuccess(
            toolCall,
            content: "Removed task \(taskIdString) from plan.md.",
            baseMetadata: [
                "source": .string("agent_plan_tool"),
                "action": .string("delete_plan_task"),
                "conversationId": .string(conversationIdString),
                "taskId": .string(taskIdString),
            ],
            planMarkdown: newText
        )
    }

    private func executeAddPlanNote(_ toolCall: ToolCall) async throws -> ToolResult {
        let bound = await bindConversationOrError(for: toolCall)
        if let error = bound.error {
            return error
        }
        let conversationId = bound.id
        let conversationIdString = bound.idString
        guard let note = extractString(from: toolCall.arguments, key: "note") else {
            throw Error.missingParameter("note")
        }


        let url = AgentPlanStore.planURL(for: conversationId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return toolError(toolCall, "No plan.md for this conversation.")
        }

        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return toolError(toolCall, "note must not be empty.")
        }

        let newText = Self.appendingNote(note, to: text)
        try newText.write(to: url, atomically: true, encoding: .utf8)

        logger?.info(
            "add_plan_note",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIdString)),
                ("toolCallId", .string(toolCall.id ?? "nil"))
            )
        )

        return planToolSuccess(
            toolCall,
            content: "Appended to ## Notes in plan.md.",
            baseMetadata: [
                "source": .string("agent_plan_tool"),
                "action": .string("add_plan_note"),
                "conversationId": .string(conversationIdString),
            ],
            planMarkdown: newText
        )
    }

    private func executeGetPlan(_ toolCall: ToolCall) async throws -> ToolResult {
        let bound = await bindConversationOrError(for: toolCall)
        if let error = bound.error {
            return error
        }
        let conversationId = bound.id
        let conversationIdString = bound.idString

        let url = AgentPlanStore.planURL(for: conversationId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return planToolSuccess(
                toolCall,
                content: "No plan.md yet for this conversation. Use create_plan to add one.",
                baseMetadata: [
                    "source": .string("agent_plan_tool"),
                    "action": .string("get_plan"),
                    "conversationId": .string(conversationIdString),
                ],
                planMarkdown: nil
            )
        }

        return planToolSuccess(
            toolCall,
            content: text,
            baseMetadata: [
                "source": .string("agent_plan_tool"),
                "action": .string("get_plan"),
                "conversationId": .string(conversationIdString),
            ],
            planMarkdown: text
        )
    }

    private func executeDeclareAgentBuildComplete(_ toolCall: ToolCall) async throws -> ToolResult {
        let bound = await bindConversationOrError(for: toolCall)
        if let error = bound.error {
            return error
        }
        let conversationId = bound.id
        let conversationIdString = bound.idString

        let url = AgentPlanStore.planURL(for: conversationId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return toolError(toolCall, "No plan.md for this conversation.")
        }

        guard AgentPlanParser.isPlanFullyComplete(in: text) else {
            return toolError(
                toolCall,
                "Plan is not fully complete: every task line must be [x] with no blocked ([!]) lines and at least one task must exist."
            )
        }

        logger?.info(
            "declare_agent_build_complete",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIdString)),
                ("toolCallId", .string(toolCall.id ?? "nil"))
            )
        )

        return planToolSuccess(
            toolCall,
            content: "Build phase declared complete; all plan task lines are marked done.",
            baseMetadata: [
                "source": .string("agent_plan_tool"),
                "action": .string(Self.declareAgentBuildCompleteToolName),
                "conversationId": .string(conversationIdString),
            ],
            planMarkdown: text
        )
    }

    private func planToolSuccess(
        _ toolCall: ToolCall,
        content: String,
        baseMetadata: [String: JSON],
        planMarkdown: String?
    ) -> ToolResult {
        var metadata = baseMetadata
        let snapshot: PlanWireSnapshot
        if let planMarkdown {
            snapshot = PlanWireSnapshot.from(markdown: planMarkdown, exists: true)
        } else {
            snapshot = .missing
        }
        for (key, value) in snapshot.metadataFragment() {
            metadata[key] = value
        }
        return ToolResult(
            success: true,
            content: content,
            metadata: .object(metadata),
            toolCallId: toolCall.id
        )
    }

    private func toolError(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(
            success: false,
            content: "",
            metadata: .object(["source": .string("agent_plan_tool")]),
            toolCallId: toolCall.id,
            error: message
        )
    }


    /// Conversation identity is bound from runtime scope — never from model-supplied arguments.
    private func bindConversationOrError(for toolCall: ToolCall) async -> (id: UUID, idString: String, error: ToolResult?) {
        guard let conversationId = await resolveConversationID() else {
            return (UUID(), "", toolError(toolCall, "No active conversation"))
        }
        let conversationIdString = conversationId.uuidString
        guard await dataProvider.getConversation(id: conversationId) != nil else {
            return (conversationId, conversationIdString, toolError(toolCall, "Conversation not found: \(conversationIdString)"))
        }
        return (conversationId, conversationIdString, nil)
    }

    private func decodeTasksJSON(_ json: String) throws -> [PlanTaskInput] {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        return try decoder.decode([PlanTaskInput].self, from: data)
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments,
              let value = dict[key]
        else {
            return nil
        }
        if case .string(let s) = value { return s }
        return nil
    }

    // MARK: - Markdown

    static func renderPlanMarkdown(overview: String?, goal: String?, notes: String?, tasks: [PlanTaskInput]) -> String {
        let overviewBody = (overview?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "_Describe the plan here._"
        let goalBody = (goal?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "_Describe the desired outcome._"
        let notesBody = (notes?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "_No notes yet._"

        var lines: [String] = []
        lines.append("# Plan")
        lines.append(overviewBody)
        lines.append("")
        lines.append("## Goal")
        lines.append(goalBody)
        lines.append("")
        lines.append("## Notes")
        lines.append(notesBody)
        lines.append("")
        lines.append("## Tasks")
        for task in tasks {
            lines.append(taskLine(for: task))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func taskLine(for task: PlanTaskInput) -> String {
        let inner: String
        switch task.status {
        case .complete:
            inner = "x"
        case .blocked:
            inner = "!"
        case .inProgress:
            inner = "~"
        case .notStarted:
            inner = " "
        }
        let desc = task.description.replacingOccurrences(of: "\n", with: " ")
        return "[\(inner)] id:\(task.id.uuidString) - \(desc)"
    }

    /// At most one `in-progress` task. When `preferring` is set and that task is in-progress, it wins;
    /// otherwise the first in-progress task in list order is kept and later ones are demoted to `not-started`.
    internal static func enforcingAtMostOneInProgress(
        _ tasks: [PlanTaskInput],
        preferring preferredInProgressId: UUID? = nil
    ) -> [PlanTaskInput] {
        let keeper: UUID?
        if let preferredInProgressId,
           tasks.contains(where: { $0.id == preferredInProgressId && $0.status == .inProgress }) {
            keeper = preferredInProgressId
        } else {
            keeper = tasks.first(where: { $0.status == .inProgress })?.id
        }
        guard let keeper else { return tasks }
        return tasks.map { task in
            guard task.status == .inProgress, task.id != keeper else { return task }
            return PlanTaskInput(id: task.id, description: task.description, status: .notStarted)
        }
    }

    internal static func updateTaskLine(
        in markdown: String,
        taskId: UUID,
        newStatus: PlanTaskStatus?,
        newDescription: String?
    ) throws -> String {
        let migrated = PlanMarkdownParser.migrateLegacyMarkersIfNeeded(markdown)
        let doc = PlanMarkdownParser.parseDocument(migrated)
        guard let index = doc.tasks.firstIndex(where: { $0.id == taskId }) else {
            throw AgentPlanToolError.taskNotFound
        }
        var tasks = doc.tasks
        let existing = tasks[index]
        let updated = PlanTaskInput(
            id: existing.id,
            description: newDescription.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? existing.description,
            status: newStatus ?? existing.status
        )
        tasks[index] = updated
        let prefer = updated.status == .inProgress ? updated.id : nil
        tasks = enforcingAtMostOneInProgress(tasks, preferring: prefer)
        return renderPlanMarkdown(
            overview: doc.overview.isEmpty ? nil : doc.overview,
            goal: doc.goal.isEmpty ? nil : doc.goal,
            notes: doc.notes.isEmpty ? nil : doc.notes,
            tasks: tasks
        )
    }

    /// Appends a task by re-rendering from ``PlanMarkdownParser/parseDocument`` so structure stays canonical.
    internal static func addingTask(_ task: PlanTaskInput, to markdown: String) throws -> String {
        let migrated = PlanMarkdownParser.migrateLegacyMarkersIfNeeded(markdown)
        let doc = PlanMarkdownParser.parseDocument(migrated)
        if doc.tasks.contains(where: { $0.id == task.id }) {
            throw AgentPlanToolError.duplicateTaskId
        }
        var newTasks = doc.tasks
        newTasks.append(task)
        let prefer = task.status == .inProgress ? task.id : nil
        newTasks = enforcingAtMostOneInProgress(newTasks, preferring: prefer)
        return renderPlanMarkdown(
            overview: doc.overview.isEmpty ? nil : doc.overview,
            goal: doc.goal.isEmpty ? nil : doc.goal,
            notes: doc.notes.isEmpty ? nil : doc.notes,
            tasks: newTasks
        )
    }

    /// Removes a task by id via the same round-trip as ``addingTask(_:to:)``.
    internal static func removingTask(id taskId: UUID, from markdown: String) throws -> String {
        let migrated = PlanMarkdownParser.migrateLegacyMarkersIfNeeded(markdown)
        let doc = PlanMarkdownParser.parseDocument(migrated)
        let filtered = doc.tasks.filter { $0.id != taskId }
        guard filtered.count < doc.tasks.count else {
            throw AgentPlanToolError.taskNotFound
        }
        return renderPlanMarkdown(
            overview: doc.overview.isEmpty ? nil : doc.overview,
            goal: doc.goal.isEmpty ? nil : doc.goal,
            notes: doc.notes.isEmpty ? nil : doc.notes,
            tasks: filtered
        )
    }

    /// Appends a note to ``## Notes`` by re-rendering from ``PlanMarkdownParser/parseDocument``.
    internal static func appendingNote(_ note: String, to markdown: String) -> String {
        let migrated = PlanMarkdownParser.migrateLegacyMarkersIfNeeded(markdown)
        let doc = PlanMarkdownParser.parseDocument(migrated)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged: String
        if doc.notes.isEmpty {
            merged = trimmed
        } else if trimmed.isEmpty {
            merged = doc.notes
        } else {
            merged = doc.notes + "\n\n" + trimmed
        }
        return renderPlanMarkdown(
            overview: doc.overview.isEmpty ? nil : doc.overview,
            goal: doc.goal.isEmpty ? nil : doc.goal,
            notes: merged.isEmpty ? nil : merged,
            tasks: doc.tasks
        )
    }
}

// MARK: - Errors

private enum AgentPlanToolError: Swift.Error {
    case taskNotFound
    case duplicateTaskId
}

extension AgentPlanToolProvider {
    enum Error: Swift.Error, Sendable {
        case unknownTool(String)
        case missingParameter(String)
    }
}
