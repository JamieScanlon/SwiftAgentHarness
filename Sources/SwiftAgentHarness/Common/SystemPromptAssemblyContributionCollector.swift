import Foundation

struct SystemPromptAssemblyMemorySlice: Sendable, Equatable {
    let tier1Content: String?
    let snapshotGeneration: Int?
    let workspaceContent: String?
}

struct SystemPromptAssemblyContributionBundle: Sendable, Equatable {
    let assemblyContext: SystemPromptAssemblyContext
    let contributions: [SystemPromptContribution]
    let fullOverrideText: String?
    let memorySlice: SystemPromptAssemblyMemorySlice
    let providerContributionSignature: String?
}

enum SystemPromptAssemblyContributionCollector {
    static func collect(
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        userSystemPrompt: String?,
        memoryBlocks: MemorySystemPromptBlocks?,
        memorySnapshotGeneration: Int?,
        modeMemoryInjection: String,
        engineDynamicAddition: String? = nil,
        referenceDate: Date = Date()
    ) -> SystemPromptAssemblyContributionBundle {
        let modeSwitches = ContextSystemPromptModeSwitches.build(
            conversation: conversation,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            resolvedProfile: policy.resolvedModeProfile,
            referenceDate: referenceDate
        )
        var assemblyContext = modeSwitches.assemblyContext
        let omitWorkspace = policy.resolvedModeProfile.context.omitWorkspaceConventions == true

        let memorySlice = memorySliceContent(
            blocks: memoryBlocks,
            snapshotGeneration: memorySnapshotGeneration,
            modeMemoryInjection: modeMemoryInjection,
            includeAgentSkills: assemblyContext.includeAgentSkills
        )
        let resolvedMemorySlice: SystemPromptAssemblyMemorySlice = if omitWorkspace {
            SystemPromptAssemblyMemorySlice(
                tier1Content: memorySlice.tier1Content,
                snapshotGeneration: memorySlice.snapshotGeneration,
                workspaceContent: nil
            )
        } else {
            memorySlice
        }
        if let tier1 = resolvedMemorySlice.tier1Content {
            assemblyContext.tier1MemoryContent = tier1
        }
        assemblyContext.memorySnapshotGeneration = resolvedMemorySlice.snapshotGeneration

        var contributions: [SystemPromptContribution] = []
        if let provider = policy.providerContribution {
            contributions.append(provider)
        }
        contributions.append(modeSwitches.modeContribution)

        let compositionMode = ConversationMetadataSubagentPromptComposition.promptCompositionMode(from: conversation.metadata)
            ?? (conversation.lineageKind == .subAgent ? .spawn : nil)
        if compositionMode == .spawn {
            var spawnContribution = SystemPromptContribution(source: .engine)
            spawnContribution.suppress = SystemPromptSubagentComposition.spawnSectionSuppressions
            contributions.append(spawnContribution)
        }

        if !omitWorkspace,
           compositionMode != .spawn,
           let workspace = resolvedMemorySlice.workspaceContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspace.isEmpty {
            contributions.append(
                SystemPromptContribution(
                    source: .workspace,
                    sectionOverrides: [.personality: workspace]
                )
            )
        }

        if let memoryBody = SystemPrompt.memoryLayerSectionOverride(
            memoryInjectionMode: modeMemoryInjection,
            includeAgentSkills: assemblyContext.includeAgentSkills,
            tier1Content: memorySlice.tier1Content ?? ""
        ), compositionMode != .spawn {
            contributions.append(
                SystemPromptContribution(
                    source: .memory,
                    sectionOverrides: [.memory: memoryBody]
                )
            )
        }

        var conversationDirectiveParts: [String] = []
        if let extra = conversation.extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extra.isEmpty {
            conversationDirectiveParts.append(extra)
        }
        if let userPrompt = userSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userPrompt.isEmpty {
            conversationDirectiveParts.append(userPrompt)
        }
        if !conversationDirectiveParts.isEmpty {
            contributions.append(
                SystemPromptContribution(
                    source: .conversation,
                    sectionDirectives: [.extraInstructions: conversationDirectiveParts.joined(separator: "\n\n")]
                )
            )
        }

        if let addition = engineDynamicAddition?.trimmingCharacters(in: .whitespacesAndNewlines),
           !addition.isEmpty {
            contributions.append(
                SystemPromptContribution(
                    source: .engine,
                    sectionDirectives: [.dynamicAdditions: addition]
                )
            )
        }

        let fullOverrideText: String? = if conversation.systemPromptFullOverride {
            userSystemPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } else {
            nil
        }

        let providerSig = policy.providerContribution.map(providerContributionSignature)

        return SystemPromptAssemblyContributionBundle(
            assemblyContext: assemblyContext,
            contributions: contributions,
            fullOverrideText: fullOverrideText,
            memorySlice: resolvedMemorySlice,
            providerContributionSignature: providerSig
        )
    }

    private static func memorySliceContent(
        blocks: MemorySystemPromptBlocks?,
        snapshotGeneration: Int?,
        modeMemoryInjection: String,
        includeAgentSkills: Bool
    ) -> SystemPromptAssemblyMemorySlice {
        switch modeMemoryInjection {
        case "off":
            return SystemPromptAssemblyMemorySlice(
                tier1Content: nil,
                snapshotGeneration: nil,
                workspaceContent: nil
            )
        case "skills-only":
            guard includeAgentSkills else {
                return SystemPromptAssemblyMemorySlice(
                    tier1Content: nil,
                    snapshotGeneration: nil,
                    workspaceContent: nil
                )
            }
        default:
            break
        }
        guard let blocks else {
            return SystemPromptAssemblyMemorySlice(
                tier1Content: nil,
                snapshotGeneration: nil,
                workspaceContent: nil
            )
        }
        let workspace = blocks.workspaceInstructionSection.nilIfEmpty
        let tier1 = blocks.memoryTier1Content.nilIfEmpty
        guard workspace != nil || tier1 != nil else {
            return SystemPromptAssemblyMemorySlice(
                tier1Content: nil,
                snapshotGeneration: nil,
                workspaceContent: nil
            )
        }
        return SystemPromptAssemblyMemorySlice(
            tier1Content: tier1,
            snapshotGeneration: snapshotGeneration ?? blocks.snapshotGeneration,
            workspaceContent: workspace
        )
    }

    private static func providerContributionSignature(_ contribution: SystemPromptContribution) -> String {
        var parts: [String] = ["source=\(contribution.source.rawValue)"]
        if let prefix = contribution.stablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty {
            parts.append("prefix=\(String(prefix.prefix(128)))")
        }
        if !contribution.sectionOverrides.isEmpty {
            let overrides = contribution.sectionOverrides
                .keys
                .sorted { $0.rawValue < $1.rawValue }
                .map { key in
                    let value = contribution.sectionOverrides[key] ?? ""
                    return "\(key.rawValue)=\(String(value.prefix(128)))"
                }
                .joined(separator: ",")
            parts.append("overrides=\(overrides)")
        }
        return parts.joined(separator: "|")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
