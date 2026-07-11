import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitSkills

typealias SystemPromptSkillLoaderProvider = @Sendable (UUID?) async -> SkillLoader?

/// Renders the model-facing system prompt during CE assemble (SP1).
protocol SystemPromptAssemblyRendering: Sendable {
    func render(
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        userSystemPrompt: String?,
        assemblyContext: SystemPromptAssemblyContext,
        contributions: [SystemPromptContribution],
        referenceDate: Date,
        fullOverrideText: String?
    ) async throws -> String

    func renderWithAudit(
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        userSystemPrompt: String?,
        assemblyContext: SystemPromptAssemblyContext,
        contributions: [SystemPromptContribution],
        referenceDate: Date,
        fullOverrideText: String?
    ) async throws -> SystemPromptAssemblyRenderAudit
}

extension SystemPromptAssemblyRendering {
    func render(
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        userSystemPrompt: String?,
        assemblyContext: SystemPromptAssemblyContext,
        contributions: [SystemPromptContribution],
        referenceDate: Date,
        fullOverrideText: String? = nil
    ) async throws -> String {
        try await renderWithAudit(
            conversation: conversation,
            policy: policy,
            userSystemPrompt: userSystemPrompt,
            assemblyContext: assemblyContext,
            contributions: contributions,
            referenceDate: referenceDate,
            fullOverrideText: fullOverrideText
        ).text
    }

    func renderWithAudit(
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        userSystemPrompt: String?,
        assemblyContext: SystemPromptAssemblyContext,
        contributions: [SystemPromptContribution],
        referenceDate: Date,
        fullOverrideText: String? = nil
    ) async throws -> SystemPromptAssemblyRenderAudit {
        let text = try await render(
            conversation: conversation,
            policy: policy,
            userSystemPrompt: userSystemPrompt,
            assemblyContext: assemblyContext,
            contributions: contributions,
            referenceDate: referenceDate,
            fullOverrideText: fullOverrideText
        )
        return SystemPromptAssemblyRenderAudit(
            text: text,
            product: SystemPromptAssemblyRenderProduct(
                text: text,
                sectionProvenance: [:],
                skillSnapshot: SystemPromptSkillRenderSnapshot(
                    activatedSkillNames: [],
                    skillsIndexDigest: nil
                ),
                frozenSkillsIndexXML: nil
            ),
            effectiveUserSystemPrompt: userSystemPrompt ?? assemblyContext.userSystemPrompt,
            providerStablePrefix: nil
        )
    }
}

/// Bridges skill-loader access configured after ``HarnessRuntimeSession`` services bootstrap.
final class SystemPromptSkillLoaderBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: SystemPromptSkillLoaderProvider?

    func configure(provider: @escaping SystemPromptSkillLoaderProvider) {
        lock.withLock {
            self.provider = provider
        }
    }

    func skillLoader(for conversationID: UUID?) async -> SkillLoader? {
        let provider = lock.withLock { self.provider }
        guard let provider else { return nil }
        return await provider(conversationID)
    }
}

struct DefaultSystemPromptAssemblyRenderer: SystemPromptAssemblyRendering {
    let skillLoaderProvider: SystemPromptSkillLoaderProvider
    let logger: Logger?

    func renderWithAudit(
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        userSystemPrompt: String?,
        assemblyContext: SystemPromptAssemblyContext,
        contributions: [SystemPromptContribution],
        referenceDate: Date,
        fullOverrideText: String? = nil
    ) async throws -> SystemPromptAssemblyRenderAudit {
        if conversation.systemPromptFullOverride {
            logger?.warning("[DefaultSystemPromptAssemblyRenderer] systemPromptFullOverride active for conversation \(conversation.id)")
            let text = fullOverrideText ?? userSystemPrompt ?? conversation.systemPrompt
            return SystemPromptAssemblyRenderAudit(
                text: text,
                product: SystemPromptAssemblyRenderProduct(
                    text: text,
                    sectionProvenance: [:],
                    skillSnapshot: SystemPromptSkillRenderSnapshot(
                        activatedSkillNames: [],
                        skillsIndexDigest: nil
                    ),
                    frozenSkillsIndexXML: nil
                ),
                effectiveUserSystemPrompt: userSystemPrompt ?? conversation.systemPrompt,
                providerStablePrefix: nil
            )
        }
        let skillLoader = await skillLoaderProvider(conversation.id)
        let modeCtx = ModePolicyContext(
            interactionMode: conversation.interactionMode,
            resolvedProfile: policy.resolvedModeProfile
        )
        var context = assemblyContext
        context.referenceDate = referenceDate
        if context.frozenSkillsIndexXML == nil {
            context.frozenSkillsIndexXML = ConversationMetadataFrozenSkillsIndex.frozenSkillsIndexXML(
                from: conversation.metadata
            )
        }
        let conversationHandlesExtraInstructions = contributions.contains {
            $0.source == .conversation && $0.sectionDirectives[.extraInstructions] != nil
        }
        let effectiveUserSystemPrompt: String
        if conversationHandlesExtraInstructions {
            context.userSystemPrompt = ""
            effectiveUserSystemPrompt = ""
        } else if let userSystemPrompt {
            context.userSystemPrompt = userSystemPrompt
            effectiveUserSystemPrompt = userSystemPrompt
        } else {
            effectiveUserSystemPrompt = context.userSystemPrompt
        }
        let resolution = try SystemPromptContributionResolver.resolve(contributions: contributions)
        let providerID = SystemPromptAssemblyProviderIdentity.providerID(from: policy.providerContribution)
        let modeProfileID = context.registryProfileID
        do {
            let systemPrompt = try await SystemPrompt(
                includeCurrentDateTime: policy.includeDateTime ? nil : false,
                includeAgentSkills: policy.includeAgentSkills,
                skillLoader: skillLoader,
                skipConfigLoad: false,
                allowSkillLoaderAbsence: context.frozenSkillsIndexXML != nil,
                logger: logger,
                interactionMode: conversation.interactionMode,
                assemblyKind: policy.resolvedModeProfile.assemblyKind,
                routingPolicyConversation: conversation,
                modePolicyContext: modeCtx
            )
            let product = try await systemPrompt.renderAssemblyProduct(
                context: context,
                resolved: resolution.resolved,
                stablePrefix: resolution.stablePrefix,
                providerID: providerID,
                modeProfileID: modeProfileID
            )
            return SystemPromptAssemblyRenderAudit(
                text: product.text,
                product: product,
                effectiveUserSystemPrompt: effectiveUserSystemPrompt,
                providerStablePrefix: resolution.stablePrefix
            )
        } catch {
            logger?.warning(
                "[DefaultSystemPromptAssemblyRenderer] System prompt build failed, retrying without agent skills: \(error)"
            )
            let fallbackPrompt = try await SystemPrompt(
                includeCurrentDateTime: nil,
                includeAgentSkills: false,
                skillLoader: skillLoader,
                logger: logger,
                interactionMode: conversation.interactionMode,
                assemblyKind: policy.resolvedModeProfile.assemblyKind,
                routingPolicyConversation: conversation,
                modePolicyContext: modeCtx
            )
            let product = try await fallbackPrompt.renderAssemblyProduct(
                context: context,
                resolved: resolution.resolved,
                stablePrefix: resolution.stablePrefix,
                providerID: providerID,
                modeProfileID: modeProfileID
            )
            return SystemPromptAssemblyRenderAudit(
                text: product.text,
                product: product,
                effectiveUserSystemPrompt: effectiveUserSystemPrompt,
                providerStablePrefix: resolution.stablePrefix
            )
        }
    }
}

enum SystemPromptAssemblyProviderIdentity {
    static func providerID(from contribution: SystemPromptContribution?) -> String? {
        guard let contribution, contribution.source == .provider else { return nil }
        if let prefix = contribution.stablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prefix.isEmpty,
           let range = prefix.range(of: "provider:") {
            let tail = prefix[range.upperBound...]
            let id = tail.split(separator: " ", maxSplits: 1).first.map(String.init)
            if let id, !id.isEmpty { return id }
        }
        return nil
    }
}
