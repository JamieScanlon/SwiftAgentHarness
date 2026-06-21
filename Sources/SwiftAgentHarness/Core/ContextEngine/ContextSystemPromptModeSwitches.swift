import Foundation

/// Canonical mode-context switch projection for system prompt assembly.
enum ContextSystemPromptModeSwitches {
    static let nonSuppressibleSectionIDs: Set<String> = ["constraints"]

    struct Result: Sendable {
        let metadata: [String: String]
        let suppressions: Set<String>
        let sectionOverrides: [String: String]
        let memoryInjectionMode: String
    }

    static func build(
        conversation: ModelConversation,
        strictAgentHarnessPrompts: Bool,
        resolvedProfile: ResolvedModeProfile
    ) -> Result {
        let conversationStartDate: Date = {
            if let systemMessage = conversation.messages.first(where: { $0.role == .system }) {
                return systemMessage.timestamp
            }
            return conversation.messages.map(\.timestamp).min() ?? conversation.updatedAt
        }()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let context = resolvedProfile.context
        let directive = context.modeDirective?.trimmedOrNil
        let compactionLevel = context.compactionLevel?.trimmedOrNil
        let requestedMemoryMode = context.memoryInjection?.trimmedLowercasedOrNil
        let memoryMode = normalizedMemoryInjectionMode(raw: requestedMemoryMode)
        let suppressions = normalizedSuppressions(context.suppressSections)
        let sectionOverrides = normalizedSectionOverrides(context.sectionOverrides)

        var metadata: [String: String] = [
            "conversationID": conversation.id.uuidString,
            "conversationStartDate": isoFormatter.string(from: conversationStartDate),
            "registryProfileId": resolvedProfile.id,
            "modeMemoryInjection": memoryMode,
            "modeIncludeSkills": String(context.includeSkills ?? true),
            "modeIncludeToolGuidance": String(context.includeToolGuidance ?? true),
        ]
        if let directive {
            metadata["modeDirective"] = directive
        }
        if let compactionLevel {
            metadata["modeCompactionLevel"] = compactionLevel
        }
        if !suppressions.isEmpty {
            metadata["modeSuppressSections"] = suppressions.sorted().joined(separator: ",")
        }
        for (key, value) in sectionOverrides {
            metadata["modeSectionOverride.\(key)"] = value
        }
        if conversation.interactionMode == .plan || conversation.interactionMode == .agent {
            let planPath = AgentPlanStore.planPathString(for: conversation.id)
            metadata["interactionMode"] = conversation.interactionMode.rawValue
            metadata["planPath"] = planPath
            metadata["agentWorkflowBlock"] = agentWorkflowPromptBlock(
                for: conversation,
                strictAgentHarnessPrompts: strictAgentHarnessPrompts
            )
        }
        var mergedOverrides = sectionOverrides
        if conversation.lineageKind == .subAgent {
            let scope = conversation.conversationScope()
            let prompt = subAgentContextPrompt(scope: scope)
            mergedOverrides["sub_agent_context"] = prompt
            metadata["modeSectionOverride.sub_agent_context"] = prompt
            metadata["conversationLineageKind"] = conversation.lineageKind.rawValue
            metadata["conversationOrigin"] = conversation.origin.rawValue
            metadata["subAgentRootConversationID"] = scope.rootID.uuidString.lowercased()
            if let parentID = scope.parentID {
                metadata["subAgentParentConversationID"] = parentID.uuidString.lowercased()
            }
            metadata["subAgentDepth"] = String(scope.depth)
        }

        return Result(
            metadata: metadata,
            suppressions: suppressions,
            sectionOverrides: mergedOverrides,
            memoryInjectionMode: memoryMode
        )
    }

    private static func subAgentContextPrompt(scope: ConversationScope) -> String {
        let template = SystemPrompt.loadSubAgentContextTemplateFromConfig()
        let parent = scope.parentID?.uuidString.lowercased() ?? "none"
        return template
            .replacingOccurrences(of: "{{subAgentDepth}}", with: String(scope.depth))
            .replacingOccurrences(of: "{{subAgentRootConversationID}}", with: scope.rootID.uuidString.lowercased())
            .replacingOccurrences(of: "{{subAgentConversationID}}", with: scope.selfID.uuidString.lowercased())
            .replacingOccurrences(of: "{{subAgentParentConversationID}}", with: parent)
    }

    private static func normalizedMemoryInjectionMode(raw: String?) -> String {
        switch raw {
        case "off":
            return "off"
        case "skills-only":
            return "skills-only"
        default:
            return "on"
        }
    }

    private static func normalizedSuppressions(_ rawValues: [String]) -> Set<String> {
        Set(
            rawValues
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && !nonSuppressibleSectionIDs.contains($0) }
        )
    }

    private static func normalizedSectionOverrides(_ raw: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in raw {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty, !nonSuppressibleSectionIDs.contains(normalizedKey) else {
                continue
            }
            guard let normalizedValue = value.trimmedOrNil else {
                continue
            }
            normalized[normalizedKey] = normalizedValue
        }
        return normalized
    }

    private static func agentWorkflowPromptBlock(
        for conversation: ModelConversation,
        strictAgentHarnessPrompts: Bool
    ) -> String {
        switch conversation.interactionMode {
        case .chat:
            return ""
        case .plan:
            return """
### Plan workflow
Research and create the plan file via tools. Use **create_plan** and **edit_plan** with a `tasks` JSON array; optional **overview**, **goal**, and **notes** fill `# Plan`, `## Goal`, and `## Notes`. Use **add_plan_task** / **delete_plan_task** to add or remove individual tasks (parsed and rewritten like **edit_plan**, but scoped to one line). Task lines use `[ ]` not-started, `[~]` in-progress, `[/]` complete, `[x]` blocked, each with `id:<uuid>`. Use **get_plan** to read.

**Context and motivation:** Turn the **first user message** and follow-up answers into durable plan content—not only tasks. Capture why the work matters, constraints, and **operational context**: repo or project path, important file or resource locations, links to documentation, environment variable **names** (not secret values), and anything the build agent will need later. Ask clarifying questions when needed, then fold answers into **overview**, **goal**, or **notes** so the plan stays the single source of truth.

Refine until the user switches to Agent (build) mode in the app. When planning is complete and you are waiting for the user, call **finish** (or **ask_user** when you need structured input). Do **not** call **exit_plan_mode** — the user switches build mode in the app.
**IMPORTANT** DO NOT start execution work during this phase! Your only job is to plan using the plan tools (not raw shell edits to plan.md).
"""
        case .agent:
            let path = AgentPlanStore.planPathString(for: conversation.id)
            let summaryLine: String
            if let text = AgentPlanStore.readPlanText(for: conversation.id) {
                summaryLine = AgentPlanParser.planProgressSummaryLine(in: text)
            } else {
                summaryLine = "No plan.md on disk yet."
            }
            var block = """
### Build workflow
The canonical plan file is at `\(path)`. Use **get_plan** before large changes. Execute work until every task line is complete (`[/]`). Use **update_plan_task** to keep task status accurate (full **create_plan** / **edit_plan** rewrites and task list mutations are for **plan** mode). **Context is intentionally limited:** save anything you must remember later with **add_plan_note** under `## Notes` (paths, doc URLs, commands, env var **names**—never raw tokens or secret values)—otherwise it will be lost as the thread is trimmed.
**IMPORTANT** Keep plan.md truthful using the plan tools—downstream automation depends on it.
**Progress:** \(summaryLine)
"""
            if strictAgentHarnessPrompts {
                block += """

**Control loop:** Observe the thread and plan state → pick the next tool call → execute. If every task is `[/]` with none blocked, call **declare_agent_build_complete** once. Otherwise keep using tools; avoid conversational filler.
"""
            }
            return block
        }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var trimmedLowercasedOrNil: String? {
        trimmedOrNil?.lowercased()
    }
}
