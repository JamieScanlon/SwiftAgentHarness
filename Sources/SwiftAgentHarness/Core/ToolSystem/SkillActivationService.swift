import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitSkills

actor SkillActivationService {
    private let deps: ConversationRuntimeDependencies
    private var skillLoader: SkillLoader?

    init(deps: ConversationRuntimeDependencies) {
        self.deps = deps
    }


    func currentSkillLoader() async -> SkillLoader? {
        await ensureSkillLoader()
        return skillLoader
    }

    func ensureSkillLoader() async {
        guard skillLoader == nil else { return }
        do {
            if let skillsPath = try SystemPrompt.loadSkillsFolderPathFromConfig() {
                skillLoader = SkillLoader(
                    skillsDirectoryURL: URL(fileURLWithPath: skillsPath),
                    logger: deps.logger
                )
            }
        } catch {
            deps.logger?.error("[SkillActivationService] Failed to load skills config: \(error)")
        }
    }

    func persistActivatedSkillNamesToConversation(conversationID: UUID, names: Set<String>) async throws {
        guard var c = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        c.metadata = ConversationMetadataActivatedSkills.mergingActivatedAgentSkillNames(names, into: c.metadata)
        c.updatedAt = Date()
        await deps.persistenceDomain.replaceConversationInRegistry(c)
        if let metadata = c.metadata {
            try await deps.persistenceDomain.persistConversationMetadataToCache(conversationID: conversationID, metadata: metadata)
        }
    }

    func persistSkillLoaderStateIntoConversationMetadata(_ conversationID: UUID) async throws {
        guard SystemPrompt.loadIncludeAgentSkillsFromConfig() else { return }
        await ensureSkillLoader()
        guard let skillLoader else { return }
        let names = await skillLoader.activatedSkills
        guard !names.isEmpty else { return }
        try await persistActivatedSkillNamesToConversation(conversationID: conversationID, names: names)
    }

    func persistActivatedSkillsFromLoader(conversationID: UUID) async {
        do {
            guard SystemPrompt.loadIncludeAgentSkillsFromConfig() else { return }
            await ensureSkillLoader()
            guard let skillLoader else { return }
            let names = await skillLoader.activatedSkills
            try await persistActivatedSkillNamesToConversation(conversationID: conversationID, names: names)
        } catch {
            deps.logger?.warning(
                "[SkillActivationService] Failed to persist activated Agent Skills to conversation metadata: \(error)"
            )
        }
    }

    func listAvailableSkillsForSlash(conversationID: UUID) async throws -> [AvailableSkillInfo] {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        guard SystemPrompt.loadIncludeAgentSkillsFromConfig() else {
            return []
        }
        guard let skillLoader = await currentSkillLoader() else {
            return []
        }
        let all = try await skillLoader.loadMetadata()
        let policyCtx = await modePolicyContext(for: conversation)
        let eligible = all.filter {
            policyCtx.resolvedProfile.skills.isSkillAllowed(name: $0.name, context: policyCtx)
                && ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(
                    name: $0.name,
                    conversation: conversation
                )
        }
        return eligible.map {
            AvailableSkillInfo(name: $0.name, description: $0.description)
        }
    }

    func filteredActivatableSkillNames(from stored: [String], conversation: ModelConversation) async -> [String] {
        await ensureSkillLoader()
        guard let skillLoader else { return [] }
        var result: [String] = []
        for name in stored.sorted() {
            let policyCtx = await modePolicyContext(for: conversation)
            guard policyCtx.resolvedProfile.skills.isSkillAllowed(name: name, context: policyCtx) else { continue }
            guard ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(name: name, conversation: conversation) else { continue }
            guard (try? await skillLoader.loadSkill(named: name)) != nil else { continue }
            result.append(name)
        }
        return result
    }

    func restoreSkillLoader(for conversationID: UUID) async throws {
        guard SystemPrompt.loadIncludeAgentSkillsFromConfig() else { return }
        await ensureSkillLoader()
        guard let skillLoader else { return }
        guard let conv = await deps.persistenceDomain.modelConversation(id: conversationID) else { return }

        let stored = ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: conv.metadata)
        await skillLoader.deactivateAllSkills()
        let filtered = await filteredActivatableSkillNames(from: stored, conversation: conv)
        for name in filtered {
            await skillLoader.activateSkill(named: name)
        }
    }

    func activateSkillForSlash(
        conversationID: UUID,
        skillName: String,
        eligibleSkills: [AvailableSkillInfo]
    ) async throws -> Set<String> {
        await ensureSkillLoader()
        guard let skillLoader else {
            throw SkillActivationSlashError.skillsUnavailable
        }
        guard let match = eligibleSkills.first(where: { $0.name.lowercased() == skillName.lowercased() }) else {
            throw SkillActivationSlashError.unknownSkill(skillName)
        }
        await skillLoader.activateSkill(named: match.name)
        let names = await skillLoader.activatedSkills
        try await persistActivatedSkillNamesToConversation(conversationID: conversationID, names: names)
        return names
    }

    private func modePolicyContext(for conversation: ModelConversation) async -> ModePolicyContext {
        let profile = await ContextEngineProjectionPolicyBuilder.resolvedModeProfile(
            for: conversation,
            modeRegistry: deps.modeRegistry,
            logger: deps.logger
        )
        return ModePolicyContext(conversation: conversation, resolvedProfile: profile)
    }
}

enum SkillActivationSlashError: Error, Sendable {
    case skillsUnavailable
    case unknownSkill(String)
}
