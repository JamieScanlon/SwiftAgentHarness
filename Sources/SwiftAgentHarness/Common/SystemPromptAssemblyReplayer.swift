import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitSkills

enum SystemPromptAssemblyReplayer {
    static func reassemble(
        conversation: ModelConversation,
        messagesAtFrontier: [Message],
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        replaySpec: SystemPromptAssemblyReplaySpec,
        memoryBlocks: MemorySystemPromptBlocks?,
        memorySnapshotGeneration: Int?,
        frozenSkillsIndexXML: String?,
        skillLoader: SkillLoader?,
        logger: Logger?
    ) async throws -> String {
        let referenceDate = SystemPrompt.referenceDate(fromAssembleReferenceDateISO: replaySpec.assembleReferenceDateISO)
            ?? Date()
        let userSystemPrompt = replaySpec.userSystemPrompt
        let strictPrompts = replaySpec.promptConfigSnapshot.strictAgentHarnessPrompts
        let modeMemoryInjection = ContextSystemPromptModeSwitches.build(
            conversation: conversation,
            strictAgentHarnessPrompts: strictPrompts,
            resolvedProfile: policy.resolvedModeProfile,
            referenceDate: referenceDate
        ).memoryInjectionMode
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conversation,
            policy: policy,
            userSystemPrompt: userSystemPrompt.nilIfEmpty == nil ? SystemPromptAssemblyApplicator.userSystemPrompt(from: messagesAtFrontier) : userSystemPrompt,
            memoryBlocks: memoryBlocks,
            memorySnapshotGeneration: memorySnapshotGeneration,
            modeMemoryInjection: modeMemoryInjection,
            engineDynamicAddition: nil,
            referenceDate: referenceDate
        )
        var assemblyContext = bundle.assemblyContext
        if let frozenSkillsIndexXML {
            assemblyContext.frozenSkillsIndexXML = frozenSkillsIndexXML
            if let expectedDigest = replaySpec.skillsIndexDigest {
                let actual = SystemPromptDispatchCodec.sha256Digest(of: frozenSkillsIndexXML)
                if actual != expectedDigest {
                    logger?.warning(
                        "[SystemPromptAssemblyReplayer] frozen skills index digest mismatch; replay may differ from assemble"
                    )
                }
            }
        } else if let expectedDigest = replaySpec.skillsIndexDigest, let skillLoader {
            let metadata = try await skillLoader.loadMetadata()
            let xml = SkillPromptFormatter.formatAsXML(metadata)
            let actual = SystemPromptDispatchCodec.sha256Digest(of: xml)
            if actual != expectedDigest {
                logger?.warning(
                    "[SystemPromptAssemblyReplayer] skills index digest mismatch for loader snapshot; replay may differ from assemble"
                )
            }
            assemblyContext.frozenSkillsIndexXML = xml
        }
        let renderer = DefaultSystemPromptAssemblyRenderer(
            skillLoaderProvider: { _ in skillLoader },
            logger: logger
        )
        let audit = try await renderer.renderWithAudit(
            conversation: conversation,
            policy: policy,
            userSystemPrompt: userSystemPrompt.nilIfEmpty == nil ? nil : userSystemPrompt,
            assemblyContext: assemblyContext,
            contributions: bundle.contributions,
            referenceDate: referenceDate,
            fullOverrideText: bundle.fullOverrideText
        )
        return audit.text
    }

    static func buildReplaySpec(
        assemblyFingerprint: String,
        assembleReferenceDateISO: String,
        audit: SystemPromptAssemblyRenderAudit,
        contributions: [SystemPromptContribution],
        policy: ContextEngineSystemPromptAssemblyPolicyInput? = nil,
        promptConfigSnapshot: PromptAssemblyConfigSnapshot? = nil
    ) -> SystemPromptAssemblyReplaySpec {
        let snapshot = promptConfigSnapshot
            ?? snapshot(from: policy)
            ?? PromptAssemblyConfigSnapshot(from: .default, strictAgentHarnessPrompts: true)
        return SystemPromptAssemblyReplaySpec.build(
            assemblyFingerprint: assemblyFingerprint,
            assembleReferenceDateISO: assembleReferenceDateISO,
            userSystemPrompt: audit.effectiveUserSystemPrompt,
            skillSnapshot: audit.product.skillSnapshot,
            providerStablePrefix: audit.providerStablePrefix,
            contributions: contributions,
            promptConfigSnapshot: snapshot
        )
    }

    /// Builds a capture-time snapshot from assembly policy.
    static func snapshot(
        from policy: ContextEngineSystemPromptAssemblyPolicyInput?
    ) -> PromptAssemblyConfigSnapshot? {
        guard let policy else { return nil }
        return PromptAssemblyConfigSnapshot(
            from: PromptAssemblyConfiguration(
                includeCurrentDateTime: policy.includeDateTime,
                includeAgentSkills: policy.includeAgentSkills,
                skillsFolderPath: PromptAssemblyConfiguration.default.skillsFolderPath,
                subAgentContextTemplate: PromptAssemblyConfiguration.default.subAgentContextTemplate,
                assemblyCheckpointMode: PromptAssemblyConfiguration.default.assemblyCheckpointMode,
                assemblyCheckpointMaxFullTextBytes: PromptAssemblyConfiguration.default.assemblyCheckpointMaxFullTextBytes
            ),
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
