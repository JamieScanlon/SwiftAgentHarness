import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension SlashCommandDispatchService {
    func runSlashToolsCommand(conversationID: UUID, args: String) async throws -> ChatStreamResponse {
        guard var conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        await orchestratorRuntime.setupOrchestrator(with: conversation.model, activeConversation: conversation)
        guard let orchestrator = await agentRuntime.orchestrator(for: conversationID) else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Tool registry unavailable (orchestrator not initialized)."
            )
        }

        let entries = await orchestratorRuntime.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
        let policyConfiguration = await toolApproval.configurationApplyingToolApprovals(
            configurationApplyingTrustPolicy(HarnessRuntimeSession.Configuration()),
            conversationID: conversationID,
            runID: conversation.currentRunID
        )
        let modeCtx = await modePolicyContext(for: conversation)
        let runtimeConfiguration = AgentRuntimeTurnConfiguration(managerConfiguration: policyConfiguration)

        let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedArgs.isEmpty {
            let report = ToolPolicyAvailabilityExplainer.explain(
                entries: entries,
                conversation: conversation,
                modePolicyContext: modeCtx,
                configuration: runtimeConfiguration,
                toolPolicy: deps.toolPolicy,
                trustPolicy: deps.trustPolicyConfiguration,
                subAgentToolClassifier: subAgentPool,
                gateway: toolSystemGateway
            )
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: ToolPolicyExplainFormatter.formatList(report: report)
            )
        }

        let parts = trimmedArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let subcommand = String(parts[0]).lowercased()
        guard subcommand == "explain" else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Unknown `/tools` subcommand `\(subcommand)`. Usage: `/tools` or `/tools explain [toolName]`."
            )
        }

        var filterToolName: String?
        var gatingPreview: String?
        if parts.count > 1 {
            let remainder = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let nameParts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            filterToolName = String(nameParts[0])
            if nameParts.count > 1 {
                gatingPreview = String(nameParts[1])
            }
        }

        if let filterToolName,
           !entries.contains(where: { entry in
               ToolNamePolicyNormalization.matchesRegistryName(callName: filterToolName, entryName: entry.name)
           }) {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Tool `\(filterToolName)` is not registered in the current catalog."
            )
        }

        let report = ToolPolicyAvailabilityExplainer.explain(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: runtimeConfiguration,
            toolPolicy: deps.toolPolicy,
            trustPolicy: deps.trustPolicyConfiguration,
            subAgentToolClassifier: subAgentPool,
            gateway: toolSystemGateway,
            filterToolName: filterToolName,
            gatingArgumentPreview: gatingPreview
        )
        let coherenceReport = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: deps.toolPolicy,
            conversation: conversation,
            grantTable: deps.visibilityGrants.snapshot()
        )

        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: ToolPolicyExplainFormatter.format(report: report, coherenceReport: coherenceReport)
        )
    }
}
