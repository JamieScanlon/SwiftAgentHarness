import Foundation
import Logging
import SwiftAgentKit

enum ContextEngineProjectionPolicyBuilder {
    static func shouldEnableContextTransform(
        interactionMode: InteractionMode,
        contextCompactionLevel: String?,
        transformConfiguration: ConversationTransformConfiguration
    ) -> Bool {
        let defaultEnabled = transformConfiguration.toggles(for: interactionMode).enableContextTransform
        guard let level = contextCompactionLevel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !level.isEmpty
        else {
            return defaultEnabled
        }
        switch level {
        case "off":
            return false
        case "shallow", "full":
            return true
        default:
            return defaultEnabled
        }
    }

    static func resolvedModeProfile(
        for conversation: ModelConversation,
        modeRegistry: any ModeRegistryAccessing,
        logger: Logger?
    ) async -> ResolvedModeProfile {
        (await modeRegistry.resolveReportingFallback(
            modeId: conversation.modeProfileID ?? conversation.interactionMode.rawValue,
            logger: logger,
            fallbackModeId: InteractionMode.chat.rawValue
        )).profile
    }

    static func trustAdjustedInputTrustRaw(
        configuration: HarnessRuntimeSession.Configuration?,
        trustPolicy: TrustPolicyConfiguration
    ) -> String? {
        guard var configuration else { return nil }
        configuration.inputTrustRaw = MessageInputTrustCodec.sanitizedInputTrustRaw(configuration.inputTrustRaw)
        return configuration.inputTrustRaw
    }

    static func buildProjectionPolicy(
        deps: ConversationRuntimeDependencies,
        conversation: ModelConversation,
        configuration: HarnessRuntimeSession.Configuration?
    ) async -> ContextEngineProjectionPolicyInput {
        let trustRaw = trustAdjustedInputTrustRaw(
            configuration: configuration,
            trustPolicy: deps.trustPolicyConfiguration
        )
        let hygiene = ContextCompactionPolicy
            .resolvedDeterministicHygienePolicy(config: deps.conversationTransformConfiguration.contextCompaction)
            .attachmentDocumentHygiene
        let resolvedProfile = await resolvedModeProfile(
            for: conversation,
            modeRegistry: deps.modeRegistry,
            logger: deps.logger
        )
        let routingNames = ConversationRoutingPolicyNames.names(for: conversation)
        let promptPolicy = ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: resolvedProfile,
            strictAgentHarnessPrompts: deps.agentHarness.strictAgentHarnessPrompts,
            includeAgentSkills: resolvedProfile.context.includeSkills ?? SystemPrompt.loadIncludeAgentSkillsFromConfig(),
            includeDateTime: SystemPrompt.loadIncludeCurrentDateTimeFromConfig(),
            toolPolicySignature: deps.toolPolicy.stableAllowlistSignature(),
            routingPolicyTools: routingNames.tools,
            routingPolicySkills: routingNames.skills
        )
        let compactionCfg = deps.conversationTransformConfiguration.contextCompaction
        var transcriptEntries: [SessionTranscriptEntry]?
        if compactionCfg.useSessionTreeProjection,
           let entries = try? await deps.persistenceDomain.sessionTreeTranscriptEntries(conversationID: conversation.id),
           !entries.isEmpty {
            transcriptEntries = entries
        }
        return ContextEngineProjectionPolicyInput(
            requestInputTrustRaw: trustRaw,
            safeDefaultTrustClass: deps.trustPolicyConfiguration.safeDefaultClass,
            downgradeLowTrustContext: deps.trustPolicyConfiguration.shouldDowngradeContext(for: .lowTrust),
            deterministicAttachmentHygiene: hygiene,
            attachmentCatalog: conversation.attachmentsCatalog,
            modelSupportsVision: conversation.model.capabilities.contains(.vision),
            systemPromptAssemblyPolicy: promptPolicy,
            attachmentProjectionPolicy: ContextEngineAttachmentProjectionPolicyInput(),
            useSessionTreeProjection: compactionCfg.useSessionTreeProjection,
            sessionTranscriptEntries: transcriptEntries
        )
    }

    static func makeProjectionContext(
        deps: ConversationRuntimeDependencies,
        conversation: ModelConversation,
        configuration: HarnessRuntimeSession.Configuration?,
        tokenSnapshots: (lastPromptTokens: Int?, lastContextLimitTokens: Int?)
    ) async -> ContextEngineProjectionContext {
        let resolvedMode = await resolvedModeProfile(
            for: conversation,
            modeRegistry: deps.modeRegistry,
            logger: deps.logger
        )
        let enableCT = shouldEnableContextTransform(
            interactionMode: conversation.interactionMode,
            contextCompactionLevel: resolvedMode.context.compactionLevel,
            transformConfiguration: deps.conversationTransformConfiguration
        )
        let projectionPolicy = await buildProjectionPolicy(
            deps: deps,
            conversation: conversation,
            configuration: configuration
        )
        return ContextEngineProjectionContext(
            lastPromptTokens: tokenSnapshots.lastPromptTokens,
            lastContextLimitTokens: tokenSnapshots.lastContextLimitTokens,
            resolvedMode: resolvedMode,
            enableContextTransform: enableCT,
            projectionPolicy: projectionPolicy
        )
    }
}
