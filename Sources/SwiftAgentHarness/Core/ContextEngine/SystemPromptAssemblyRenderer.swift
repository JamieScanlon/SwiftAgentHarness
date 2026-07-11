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

    func render(
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        userSystemPrompt: String?,
        assemblyContext: SystemPromptAssemblyContext,
        contributions: [SystemPromptContribution],
        referenceDate: Date,
        fullOverrideText: String? = nil
    ) async throws -> String {
        if conversation.systemPromptFullOverride {
            logger?.warning("[DefaultSystemPromptAssemblyRenderer] systemPromptFullOverride active for conversation \(conversation.id)")
            return fullOverrideText ?? userSystemPrompt ?? conversation.systemPrompt
        }
        let skillLoader = await skillLoaderProvider(conversation.id)
        let modeCtx = ModePolicyContext(
            interactionMode: conversation.interactionMode,
            resolvedProfile: policy.resolvedModeProfile
        )
        var context = assemblyContext
        context.referenceDate = referenceDate
        let conversationHandlesExtraInstructions = contributions.contains {
            $0.source == .conversation && $0.sectionDirectives[.extraInstructions] != nil
        }
        if conversationHandlesExtraInstructions {
            context.userSystemPrompt = ""
        } else if let userSystemPrompt {
            context.userSystemPrompt = userSystemPrompt
        }
        let resolution = try SystemPromptContributionResolver.resolve(contributions: contributions)
        do {
            let systemPrompt = try await SystemPrompt(
                skillLoader: skillLoader,
                logger: logger,
                interactionMode: conversation.interactionMode,
                assemblyKind: policy.resolvedModeProfile.assemblyKind,
                routingPolicyConversation: conversation,
                modePolicyContext: modeCtx
            )
            return try await systemPrompt.generateSystemPrompt(
                context: context,
                resolved: resolution.resolved,
                stablePrefix: resolution.stablePrefix
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
            return try await fallbackPrompt.generateSystemPrompt(
                context: context,
                resolved: resolution.resolved,
                stablePrefix: resolution.stablePrefix
            )
        }
    }
}
