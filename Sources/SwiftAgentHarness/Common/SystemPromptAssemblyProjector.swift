import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitSkills

enum ConversationProjectionConfigOptions {
    static func bool(_ options: JSON?, key: String) -> Bool {
        guard let options, case .object(let dict) = options,
              let value = dict[key] else { return false }
        if case .boolean(let b) = value { return b }
        if case .string(let s) = value {
            return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        }
        return false
    }

    static func int(_ options: JSON?, key: String) -> Int? {
        guard let options, case .object(let dict) = options,
              let value = dict[key] else { return nil }
        switch value {
        case .integer(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }
}

enum SystemPromptAssemblyProjector {
    static func includeAssembledSystemPrompt(in request: ConversationProjectRequest) -> Bool {
        ConversationProjectionConfigOptions.bool(request.config?.options, key: "includeAssembledSystemPrompt")
    }

    static func atEventID(in request: ConversationProjectRequest, defaultFrontier: Int) -> Int {
        ConversationProjectionConfigOptions.int(request.config?.options, key: "atEventID") ?? defaultFrontier
    }

    static func projectAssembledSystemPrompt(
        conversation: ModelConversation,
        messages: [Message],
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        skillLoaderProvider: @escaping @Sendable (UUID?) async -> SkillLoader?,
        memoryBlocksProvider: @escaping @Sendable (UUID) async -> MemorySystemPromptBlocks?,
        memoryGenerationProvider: @escaping @Sendable (UUID) async -> Int?,
        logger: Logger?
    ) async throws -> (text: String, replaySpecDigest: String, sectionProvenance: [String: String])? {
        let userSystemPrompt = SystemPromptAssemblyApplicator.userSystemPrompt(from: messages)
        let memoryBlocks = await memoryBlocksProvider(conversation.id)
        let memoryGeneration = await memoryGenerationProvider(conversation.id)
        let modeMemoryInjection = ContextSystemPromptModeSwitches.build(
            conversation: conversation,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            resolvedProfile: policy.resolvedModeProfile
        ).memoryInjectionMode
        let referenceDate = Date()
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conversation,
            policy: policy,
            userSystemPrompt: userSystemPrompt,
            memoryBlocks: memoryBlocks,
            memorySnapshotGeneration: memoryGeneration,
            modeMemoryInjection: modeMemoryInjection,
            engineDynamicAddition: nil,
            referenceDate: referenceDate
        )
        let renderer = DefaultSystemPromptAssemblyRenderer(
            skillLoaderProvider: skillLoaderProvider,
            logger: logger
        )
        let audit = try await renderer.renderWithAudit(
            conversation: conversation,
            policy: policy,
            userSystemPrompt: userSystemPrompt,
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: referenceDate,
            fullOverrideText: bundle.fullOverrideText,
            frozenSkills: nil
        )
        let fingerprint = SystemPromptAssemblyFingerprint.hexDigest(
            resolved: policy.resolvedModeProfile,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            includeAgentSkills: policy.includeAgentSkills,
            includeDateTime: policy.includeDateTime,
            toolPolicySignature: policy.toolPolicySignature,
            routingPolicyTools: policy.routingPolicyTools,
            routingPolicySkills: policy.routingPolicySkills,
            memorySnapshotGeneration: bundle.memorySlice.snapshotGeneration,
            workspaceSectionContent: bundle.memorySlice.workspaceContent,
            memoryTier1SectionContent: bundle.memorySlice.tier1Content,
            providerContributionSignature: bundle.providerContributionSignature,
            systemPromptFullOverride: conversation.systemPromptFullOverride
        )
        let iso = SystemPrompt.assembleReferenceDateISOString(from: referenceDate)
        let replaySpec = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: fingerprint,
            assembleReferenceDateISO: iso,
            audit: audit,
            contributions: bundle.contributions
        )
        let sectionMap = SystemPromptSectionProvenanceFormatter.stringSectionProvenanceMap(from: audit.product)
        return (audit.text, replaySpec.replaySpecDigest, sectionMap)
    }
}
