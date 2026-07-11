import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitSkills

actor SkillActivationService {
    private let deps: ConversationRuntimeDependencies
    private var skillLoadersByConversationID: [UUID: SkillLoader] = [:]
    private var catalogSkillLoader: SkillLoader?
    private var testingIncludeAgentSkillsOverride: Bool?
    private var testingSkillsDirectoryURLOverride: URL?

    init(deps: ConversationRuntimeDependencies) {
        self.deps = deps
    }

    func testing_setIncludeAgentSkillsOverride(_ value: Bool?) {
        testingIncludeAgentSkillsOverride = value
    }

    func testing_setSkillsDirectoryURLOverride(_ url: URL?) {
        testingSkillsDirectoryURLOverride = url
        skillLoadersByConversationID = [:]
        catalogSkillLoader = nil
    }

    func invalidateSkillCatalog(for conversationID: UUID?) async {
        if let conversationID {
            skillLoadersByConversationID.removeValue(forKey: conversationID)
        } else {
            skillLoadersByConversationID.removeAll()
        }
        catalogSkillLoader = nil
    }

    func skillLoader(for conversationID: UUID?) async -> SkillLoader? {
        guard includeAgentSkills else { return nil }
        if let conversationID {
            return await ensureSkillLoader(for: conversationID)
        }
        return await ensureCatalogSkillLoader()
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
        guard includeAgentSkills else { return }
        guard let skillLoader = await ensureSkillLoader(for: conversationID) else { return }
        let names = await skillLoader.activatedSkills
        guard !names.isEmpty else { return }
        try await persistActivatedSkillNamesToConversation(conversationID: conversationID, names: names)
    }

    func persistActivatedSkillsFromLoader(conversationID: UUID) async {
        do {
            guard includeAgentSkills else { return }
            guard let skillLoader = await ensureSkillLoader(for: conversationID) else { return }
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
        guard includeAgentSkills else {
            return []
        }
        guard let skillLoader = await ensureCatalogSkillLoader() else {
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

    func filteredActivatableSkillNames(
        from stored: [String],
        conversation: ModelConversation,
        skillLoader: SkillLoader
    ) async -> [String] {
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
        guard includeAgentSkills else { return }
        guard let skillLoader = await ensureSkillLoader(for: conversationID) else { return }
        guard let conv = await deps.persistenceDomain.modelConversation(id: conversationID) else { return }

        let stored = ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: conv.metadata)
        await skillLoader.deactivateAllSkills()
        let filtered = await filteredActivatableSkillNames(from: stored, conversation: conv, skillLoader: skillLoader)
        for name in filtered {
            await skillLoader.activateSkill(named: name)
        }
    }

    func activateSkillForSlash(
        conversationID: UUID,
        skillName: String,
        eligibleSkills: [AvailableSkillInfo]
    ) async throws -> SlashSkillActivationResult {
        guard let skillLoader = await ensureSkillLoader(for: conversationID) else {
            throw SkillActivationSlashError.skillsUnavailable
        }
        guard let match = eligibleSkills.first(where: { $0.name.lowercased() == skillName.lowercased() }) else {
            throw SkillActivationSlashError.unknownSkill(skillName)
        }
        await skillLoader.activateSkill(named: match.name)
        guard let skill = try await skillLoader.loadSkill(named: match.name) else {
            throw SkillActivationSlashError.unknownSkill(skillName)
        }
        let names = await skillLoader.activatedSkills
        try await persistActivatedSkillNamesToConversation(conversationID: conversationID, names: names)
        let body = SkillActivationBodyFormatter.formattedActivateResult(
            name: match.name,
            fullInstructions: skill.fullInstructions
        )
        return SlashSkillActivationResult(
            skillName: match.name,
            activationBody: body,
            activatedNames: names
        )
    }

    private func ensureCatalogSkillLoader() async -> SkillLoader? {
        if let catalogSkillLoader {
            return catalogSkillLoader
        }
        guard let loader = makeSkillLoader() else { return nil }
        catalogSkillLoader = loader
        return loader
    }

    private func ensureSkillLoader(for conversationID: UUID) async -> SkillLoader? {
        if let existing = skillLoadersByConversationID[conversationID] {
            return existing
        }
        guard let loader = makeSkillLoader() else { return nil }
        skillLoadersByConversationID[conversationID] = loader
        await syncLoaderFromMetadata(loader: loader, conversationID: conversationID)
        return loader
    }

    private func syncLoaderFromMetadata(loader: SkillLoader, conversationID: UUID) async {
        guard let conv = await deps.persistenceDomain.modelConversation(id: conversationID) else { return }
        let stored = ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: conv.metadata)
        guard !stored.isEmpty else { return }
        await loader.deactivateAllSkills()
        let filtered = await filteredActivatableSkillNames(from: stored, conversation: conv, skillLoader: loader)
        for name in filtered {
            await loader.activateSkill(named: name)
        }
    }

    private var includeAgentSkills: Bool {
        if let testingIncludeAgentSkillsOverride {
            return testingIncludeAgentSkillsOverride
        }
        return SystemPrompt.loadIncludeAgentSkillsFromConfig()
    }

    private func makeSkillLoader() -> SkillLoader? {
        if let testingSkillsDirectoryURLOverride {
            return SkillLoader(
                skillsDirectoryURL: testingSkillsDirectoryURLOverride,
                logger: deps.logger
            )
        }
        do {
            if let skillsPath = try SystemPrompt.loadSkillsFolderPathFromConfig() {
                return SkillLoader(
                    skillsDirectoryURL: URL(fileURLWithPath: skillsPath),
                    logger: deps.logger
                )
            }
        } catch {
            deps.logger?.error("[SkillActivationService] Failed to load skills config: \(error)")
        }
        return nil
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

struct SlashSkillActivationResult: Sendable, Equatable {
    let skillName: String
    let activationBody: String
    let activatedNames: Set<String>
}
