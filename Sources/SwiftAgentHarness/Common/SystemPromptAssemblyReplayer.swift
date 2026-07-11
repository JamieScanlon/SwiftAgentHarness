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
        frozenSkillBodies: [String: String]?,
        skillLoader: SkillLoader?,
        logger: Logger?
    ) async throws -> String {
        let referenceDate = SystemPrompt.referenceDate(fromAssembleReferenceDateISO: replaySpec.assembleReferenceDateISO)
            ?? Date()
        let userSystemPrompt = replaySpec.userSystemPrompt
        let modeMemoryInjection = ContextSystemPromptModeSwitches.build(
            conversation: conversation,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
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
        let frozenSkills: SystemPromptFrozenSkillRenderInput?
        if let frozenSkillBodies, !frozenSkillBodies.isEmpty {
            frozenSkills = SystemPromptFrozenSkillRenderInput(
                activatedSkillBodies: frozenSkillBodies,
                skillsIndexXML: nil
            )
        } else if !replaySpec.activatedSkillBodyDigests.isEmpty, let skillLoader {
            var loaded: [String: String] = [:]
            for name in replaySpec.activatedSkillNames {
                if let skill = try await skillLoader.loadSkill(named: name) {
                    let body = skill.fullInstructions
                    if let expected = replaySpec.activatedSkillBodyDigests[name],
                       expected != SystemPromptDispatchCodec.sha256Digest(of: body) {
                        logger?.warning(
                            "[SystemPromptAssemblyReplayer] skill body digest mismatch for \(name); replay may differ from assemble"
                        )
                    }
                    loaded[name] = body
                }
            }
            frozenSkills = loaded.isEmpty ? nil : SystemPromptFrozenSkillRenderInput(
                activatedSkillBodies: loaded,
                skillsIndexXML: nil
            )
        } else {
            frozenSkills = nil
        }
        let renderer = DefaultSystemPromptAssemblyRenderer(
            skillLoaderProvider: { _ in skillLoader },
            logger: logger
        )
        let audit = try await renderer.renderWithAudit(
            conversation: conversation,
            policy: policy,
            userSystemPrompt: userSystemPrompt.nilIfEmpty == nil ? nil : userSystemPrompt,
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: referenceDate,
            fullOverrideText: bundle.fullOverrideText,
            frozenSkills: frozenSkills
        )
        return audit.text
    }

    static func buildReplaySpec(
        assemblyFingerprint: String,
        assembleReferenceDateISO: String,
        audit: SystemPromptAssemblyRenderAudit,
        contributions: [SystemPromptContribution]
    ) -> SystemPromptAssemblyReplaySpec {
        SystemPromptAssemblyReplaySpec.build(
            assemblyFingerprint: assemblyFingerprint,
            assembleReferenceDateISO: assembleReferenceDateISO,
            userSystemPrompt: audit.effectiveUserSystemPrompt,
            skillSnapshot: audit.product.skillSnapshot,
            providerStablePrefix: audit.providerStablePrefix,
            contributions: contributions
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
