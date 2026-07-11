import Foundation

struct ToolExternalContentDecision: Sendable, Equatable {
    var shouldWrap: Bool
    var source: ExternalContentSourceLabel
    var includeSecurityPreamble: Bool
    var from: String?
}

enum ToolExternalContentPolicy {
    private static let exemptTools: Set<String> = [
        TerminationToolProvider.finishToolName,
        TerminationToolProvider.askUserToolName,
        TerminationToolProvider.thinkToolName,
        ModeTransitionToolProvider.enterPlanModeToolName,
        ModeTransitionToolProvider.exitPlanModeToolName,
        AgentPlanToolProvider.createPlanToolName,
        AgentPlanToolProvider.editPlanToolName,
        AgentPlanToolProvider.updatePlanTaskToolName,
        AgentPlanToolProvider.addPlanTaskToolName,
        AgentPlanToolProvider.deletePlanTaskToolName,
        AgentPlanToolProvider.addPlanNoteToolName,
        AgentPlanToolProvider.getPlanToolName,
        AgentPlanToolProvider.declareAgentBuildCompleteToolName,
        ConversationsToolProvider.listConversationsToolName,
        ConversationsToolProvider.getConversationToolName,
        ConversationsToolProvider.switchConversationToolName,
        WorkspaceFilesystemToolProvider.writeFileToolName,
        WorkspaceFilesystemToolProvider.editFileToolName,
        WorkspaceFilesystemToolProvider.processSendKeysToolName,
        "schedule_create",
        "schedule_list",
        "schedule_delete",
        "schedule_fire_now",
        ContextCompactionToolProvider.compactConversationToolName,
        "activate_skill",
        "list_skills",
        ConversationAttachmentToolProvider.readAttachmentToolName,
    ]

    private static let webFetchTools: Set<String> = ["web_fetch"]
    private static let webSearchTools: Set<String> = ["web_search"]
    private static let filesystemReadTools: Set<String> = [
        WorkspaceFilesystemToolProvider.readFileToolName,
        WorkspaceFilesystemToolProvider.globToolName,
        WorkspaceFilesystemToolProvider.grepToolName,
        WorkspaceFilesystemToolProvider.bashToolName,
        WorkspaceFilesystemToolProvider.processToolName,
    ]

    static func resolve(toolName: String, entry: ToolRegistryEntry?) -> ToolExternalContentDecision {
        let normalized = toolName.lowercased()
        if exemptTools.contains(normalized) || normalized.hasPrefix("context_compaction") {
            return ToolExternalContentDecision(
                shouldWrap: false,
                source: .unknown,
                includeSecurityPreamble: false,
                from: nil
            )
        }
        if webFetchTools.contains(normalized) {
            return wrapDecision(source: .webFetch, from: toolName, preamble: true)
        }
        if webSearchTools.contains(normalized) {
            return wrapDecision(source: .webSearch, from: toolName, preamble: true)
        }
        if filesystemReadTools.contains(normalized) {
            return wrapDecision(source: .api, from: toolName, preamble: false)
        }
        if normalized == MemorySearchToolProvider.searchToolName
            || normalized == MemorySearchToolProvider.getToolName {
            return wrapDecision(source: .api, from: toolName, preamble: false)
        }
        if let entry {
            switch entry.transportKind {
            case .mcp, .a2a, .acp:
                return wrapDecision(source: .api, from: toolName, preamble: true)
            case .local, .unknown:
                break
            }
        }
        return wrapDecision(source: .unknown, from: toolName, preamble: true)
    }

    private static func wrapDecision(
        source: ExternalContentSourceLabel,
        from: String,
        preamble: Bool
    ) -> ToolExternalContentDecision {
        ToolExternalContentDecision(
            shouldWrap: true,
            source: source,
            includeSecurityPreamble: preamble,
            from: from
        )
    }
}
