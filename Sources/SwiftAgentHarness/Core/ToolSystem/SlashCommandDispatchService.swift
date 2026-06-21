import Foundation
import SwiftAgentKit

actor SlashCommandDispatchService {
    let deps: ConversationRuntimeDependencies
    let topics: ConversationTopicPublicationPort
    let messaging: ConversationMessagingPort
    let selection: ConversationSelectionAccessing
    let sessionProjection: SessionProjectionAccessing
    let skillActivation: SkillActivationService
    let contextProjection: ContextProjectionService
    let toolApproval: ToolApprovalRuntimeService
    let orchestratorRuntime: OrchestratorRuntimeService
    let agentRuntime: any AgentRuntimeOrchestratorBinding
    let subAgentPool: any SubAgentPooling
    let toolSystemGateway: any ToolSystemGatewaying = DefaultToolSystemGateway()
    nonisolated(unsafe) var subAgentSpawnService: SubAgentSpawnService?
    private var pendingSlashCommandsByConversationID: [UUID: [String]] = [:]
    private var isDrainingPendingSlashCommands = false

    init(
        deps: ConversationRuntimeDependencies,
        topics: ConversationTopicPublicationPort,
        messaging: ConversationMessagingPort,
        selection: ConversationSelectionAccessing,
        sessionProjection: SessionProjectionAccessing,
        skillActivation: SkillActivationService,
        contextProjection: ContextProjectionService,
        toolApproval: ToolApprovalRuntimeService,
        orchestratorRuntime: OrchestratorRuntimeService,
        agentRuntime: any AgentRuntimeOrchestratorBinding,
        subAgentPool: any SubAgentPooling
    ) {
        self.deps = deps
        self.topics = topics
        self.messaging = messaging
        self.selection = selection
        self.sessionProjection = sessionProjection
        self.skillActivation = skillActivation
        self.contextProjection = contextProjection
        self.toolApproval = toolApproval
        self.orchestratorRuntime = orchestratorRuntime
        self.agentRuntime = agentRuntime
        self.subAgentPool = subAgentPool
    }

    nonisolated func installSubAgentSpawnService(_ spawnService: SubAgentSpawnService) {
        subAgentSpawnService = spawnService
    }

    static func parseCompactSlashCommand(_ text: String) -> String? {
        let parser = SlashCommandParser()
        guard let parsed = parser.parse(text), parsed.name == "compact" else {
            return nil
        }
        return parsed.args
    }

    func pendingSlashCommandCount(conversationID: UUID) -> Int {
        pendingSlashCommandsByConversationID[conversationID]?.count ?? 0
    }

    func listSlashCommandsForAPI(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry] {
        let registry = await buildSlashCommandRegistry(conversationID: conversationID)
        return registry.autocompleteEntries(includeHidden: false)
    }

    func drainPendingSlashCommandsIfNeeded(conversationID: UUID) async {
        guard !isDrainingPendingSlashCommands else { return }
        isDrainingPendingSlashCommands = true
        defer { isDrainingPendingSlashCommands = false }
        while true {
            var q = pendingSlashCommandsByConversationID[conversationID] ?? []
            guard !q.isEmpty else { break }
            if await isSlashDispatchBlocked(conversationID: conversationID) { break }
            let raw = q.removeFirst()
            if q.isEmpty {
                pendingSlashCommandsByConversationID.removeValue(forKey: conversationID)
            } else {
                pendingSlashCommandsByConversationID[conversationID] = q
            }
            do {
                _ = try await runSlashCommandIfNeeded(raw, conversationID: conversationID, skipQueue: true)
            } catch {
                deps.logger?.warning(
                    "[SlashCommandDispatchService] Draining queued slash command failed: \(String(describing: error))"
                )
            }
        }
    }

    func runSlashCommandIfNeeded(
        _ text: String,
        conversationID: UUID,
        skipQueue: Bool = false
    ) async throws -> ChatStreamResponse? {
        guard slashCommandRuntimeConfiguration.enabled else { return nil }
        let parser = SlashCommandParser()
        guard let parsedInput = parser.parseInput(text) else { return nil }

        let registry = await buildSlashCommandRegistry(conversationID: conversationID)
        let dispatcher = SlashCommandDispatcher(registry: registry)

        switch parsedInput {
        case let .skill(skillName, args):
            guard slashCommandRuntimeConfiguration.skillSlashEnabled,
                  SystemPrompt.loadIncludeAgentSkillsFromConfig()
            else { return nil }
            if !skipQueue, await isSlashDispatchBlocked(conversationID: conversationID) {
                enqueuePendingSlashCommand(conversationID: conversationID, rawText: text)
                return try await deliverQueuedSlashAcknowledgment(conversationID: conversationID, queuedText: text)
            }
            return try await runSlashSkillActivate(
                conversationID: conversationID,
                skillName: skillName,
                args: args
            )
        case .builtin(let parsed):
            let dispatch = dispatcher.dispatchBuiltin(
                parsed: parsed,
                runtimeConfig: slashCommandRuntimeConfiguration,
                isOwner: true
            )
            switch dispatch {
            case .passthrough, .unknown, .disabled:
                return nil
            case let .local(command, innerParsed):
                if !skipQueue,
                   command.base.bypassTier == .queued,
                   await isSlashDispatchBlocked(conversationID: conversationID) {
                    enqueuePendingSlashCommand(conversationID: conversationID, rawText: text)
                    return try await deliverQueuedSlashAcknowledgment(conversationID: conversationID, queuedText: text)
                }
                switch command.base.name {
                case "compact":
                    guard slashCommandRuntimeConfiguration.compactEnabled else { return nil }
                    return try await runSlashCompactCommand(
                        conversationID: conversationID,
                        reason: innerParsed.args
                    )
                case "memory":
                    return try await runSlashMemoryCommand(
                        conversationID: conversationID,
                        filename: innerParsed.args.isEmpty ? nil : innerParsed.args
                    )
                case "init":
                    return try await runSlashInitCommand(conversationID: conversationID)
                case "approve":
                    return try await runSlashApproveCommand(
                        conversationID: conversationID,
                        args: innerParsed.args
                    )
                default:
                    return nil
                }
            case let .toolDispatch(command, innerParsed):
                if !skipQueue,
                   command.base.bypassTier == .queued,
                   await isSlashDispatchBlocked(conversationID: conversationID) {
                    enqueuePendingSlashCommand(conversationID: conversationID, rawText: text)
                    return try await deliverQueuedSlashAcknowledgment(conversationID: conversationID, queuedText: text)
                }
                return try await runSlashToolDispatch(
                    conversationID: conversationID,
                    command: command,
                    parsed: innerParsed,
                    rawText: text
                )
            case .unauthorized, .prompt, .directive:
                return nil
            }
        }
    }

    private var slashCommandRuntimeConfiguration: SlashCommandRuntimeConfiguration {
        let config = deps.conversationTransformConfiguration
        return SlashCommandRuntimeConfiguration(
            enabled: config.slashCommands.enabled,
            allowUnknownPassthrough: config.slashCommands.allowUnknownPassthrough,
            compactEnabled: config.slashCommands.compactEnabled && config.contextCompaction.manualSlashEnabled,
            skillSlashEnabled: config.slashCommands.skillSlashEnabled
        )
    }

    private func isSlashDispatchBlocked(conversationID: UUID) async -> Bool {
        guard let conv = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            return false
        }
        return conv.state == .generating || conv.agenticPhase != .idle
    }

    private func buildSlashCommandRegistry(conversationID: UUID) async -> SlashCommandRegistry {
        let slashConfig = deps.conversationTransformConfiguration.slashCommands
        let excluded = Set(deps.conversationTransformConfiguration.slashCommands.staticSkillNamesExcludedFromSkillColon)
        let baseRegistry: SlashCommandRegistry
        guard slashCommandRuntimeConfiguration.skillSlashEnabled,
              SystemPrompt.loadIncludeAgentSkillsFromConfig(),
              let skills = try? await skillActivation.listAvailableSkillsForSlash(conversationID: conversationID)
        else {
            baseRegistry = SlashCommandRegistry.builtins(compactEnabled: slashCommandRuntimeConfiguration.compactEnabled)
            return registryByAddingToolDispatchCommands(
                base: baseRegistry,
                commands: slashConfig.toolDispatchCommands
            )
        }
        baseRegistry = SlashCommandRegistry.merged(
            compactEnabled: slashCommandRuntimeConfiguration.compactEnabled,
            skills: skills,
            excludedSkillAutocompleteNames: excluded
        )
        return registryByAddingToolDispatchCommands(
            base: baseRegistry,
            commands: slashConfig.toolDispatchCommands
        )
    }

    private func registryByAddingToolDispatchCommands(
        base: SlashCommandRegistry,
        commands: [SlashCommandConfiguration.ToolDispatchCommand]
    ) -> SlashCommandRegistry {
        guard !commands.isEmpty else { return base }
        let dispatchRows: [SlashCommand] = commands.map { command in
            SlashCommand(
                base: SlashCommandBase(
                    name: command.command,
                    aliases: command.aliases,
                    description: command.description,
                    argumentHint: command.argumentHint,
                    hiddenKeywords: command.hiddenKeywords,
                    source: .plugin,
                    ownerOnly: command.ownerOnly,
                    bypassTier: command.bypassTier,
                    isEnabled: command.enabled
                ),
                kind: .toolDispatch(toolName: command.toolName, argMode: command.argMode)
            )
        }
        return SlashCommandRegistry(commands: base.commands + dispatchRows)
    }

    private func enqueuePendingSlashCommand(conversationID: UUID, rawText: String) {
        var q = pendingSlashCommandsByConversationID[conversationID] ?? []
        q.append(rawText)
        pendingSlashCommandsByConversationID[conversationID] = q
    }

    private func deliverQueuedSlashAcknowledgment(conversationID: UUID, queuedText: String) async throws -> ChatStreamResponse {
        let confirmation = "Queued: \(queuedText.trimmingCharacters(in: .whitespacesAndNewlines)) will run when the current turn finishes."
        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: confirmation,
            preserveGeneratingState: true
        )
    }

    private func runSlashSkillActivate(
        conversationID: UUID,
        skillName: String,
        args: String
    ) async throws -> ChatStreamResponse {
        let eligible = (try? await skillActivation.listAvailableSkillsForSlash(conversationID: conversationID)) ?? []
        do {
            _ = try await skillActivation.activateSkillForSlash(
                conversationID: conversationID,
                skillName: skillName,
                eligibleSkills: eligible
            )
        } catch SkillActivationSlashError.skillsUnavailable {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Agent skills are not available.",
                preserveGeneratingState: false
            )
        } catch SkillActivationSlashError.unknownSkill(let name) {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Unknown or unavailable skill `\(name)` for this conversation.",
                preserveGeneratingState: false
            )
        } catch {
            deps.logger?.warning("[SlashCommandDispatchService] /skill: activate failed: \(String(describing: error))")
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Failed to activate skill: \(error.localizedDescription)",
                preserveGeneratingState: false
            )
        }
        guard let match = eligible.first(where: { $0.name.lowercased() == skillName.lowercased() }) else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Unknown or unavailable skill `\(skillName)` for this conversation.",
                preserveGeneratingState: false
            )
        }
        var detail = "Activated skill **\(match.name)**."
        if !args.isEmpty {
            detail += " (Additional text after the skill name was not sent to the model; start a normal message to use it.)"
        }
        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: detail,
            preserveGeneratingState: false
        )
    }

    private func runSlashCompactCommand(
        conversationID: UUID,
        reason: String
    ) async throws -> ChatStreamResponse {
        let normalizedReason = reason.isEmpty ? nil : reason
        let result: ContextCompactionManualResult
        do {
            result = try await contextProjection.performManualCompaction(
                conversationID: conversationID,
                trigger: .slashCommand,
                reason: normalizedReason
            )
        } catch {
            deps.logger?.warning("[SlashCommandDispatchService] /compact slash failed: \(String(describing: error))")
            throw error
        }

        let confirmation: String
        if let refusal = result.refusalReason {
            confirmation = refusal
        } else if let noop = result.noopReason {
            confirmation = "Compaction not run: \(noop)."
        } else {
            let originalCount = result.originalMessages.count
            let compactedCount = result.compactedMessages?.count ?? originalCount
            confirmation = "Conversation compacted: \(originalCount) → \(compactedCount) messages (~\(result.promptTokens) prompt tokens, threshold \(result.thresholdTokens))."
        }
        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: confirmation,
            preserveGeneratingState: false
        )
    }
}
