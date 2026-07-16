import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationToolModePolicyRuntimeService skills catalog")
struct ConversationToolModePolicyRuntimeServiceSkillsCatalogTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .ollama,
            modelName: "skills-catalog-api:test",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
    }

    private func makeSkillsDirectory(skills: [(name: String, description: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-catalog-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for skill in skills {
            let skillDir = root.appendingPathComponent(skill.name, isDirectory: true)
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let markdown = """
            ---
            name: \(skill.name)
            description: \(skill.description)
            ---

            Instructions for \(skill.name).
            """
            try markdown.write(
                to: skillDir.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    private func makePromptAssembly(
        includeAgentSkills: Bool,
        skillsFolderPath: String?
    ) -> PromptAssemblyConfiguration {
        PromptAssemblyConfiguration(
            includeCurrentDateTime: true,
            includeAgentSkills: includeAgentSkills,
            skillsFolderPath: skillsFolderPath,
            subAgentContextTemplate: PromptAssemblyConfiguration.defaultSubAgentContextTemplate,
            assemblyCheckpointMode: .digestOnly,
            assemblyCheckpointMaxFullTextBytes: SystemPromptAssemblyCheckpointConfiguration.defaultMaxFullTextBytes
        )
    }

    private func makeSession(
        configuration: HarnessConfigurationSet,
        modeRegistry: (any ModeRegistryAccessing)? = nil
    ) throws -> HarnessRuntimeSession {
        let container = try HarnessTestModelContainer.makeInMemory()
        let domain = ConversationPersistenceDomain.makeForTesting(
            container: container,
            logger: nil,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        return HarnessRuntimeSession(
            persistenceDomain: domain,
            logger: nil,
            configuration: configuration,
            toolPolicy: .unrestricted,
            agentHarness: .default,
            conversationTransformConfiguration: .default,
            conversationTransformer: NoOpConversationTransformer(),
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            compactionCoordinator: CompactionConcurrencyCoordinator(),
            contextEngine: nil,
            modeRegistry: modeRegistry
        )
    }

    @Test("listAvailableSkillsForAPI returns disk skills from configurationSet path")
    func apiCatalogUsesLoadedSkillsFolderPath() async throws {
        let skillsRoot = try makeSkillsDirectory(skills: [
            (name: "api-catalog-skill", description: "From host PromptConfig"),
        ])
        let configuration = HarnessConfigurationSet.Builder()
            .withPromptAssembly(makePromptAssembly(includeAgentSkills: true, skillsFolderPath: skillsRoot.path))
            .build()
        let session = try makeSession(configuration: configuration)
        let conversationID = try await session.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let policy = await session.conversationToolModePolicyRuntimeService

        let scoped = try await policy.listAvailableSkillsForAPI(conversationID: conversationID)
        let global = try await policy.listAvailableSkillsForAPI()

        #expect(scoped.map(\.name) == ["api-catalog-skill"])
        #expect(global.map(\.name) == ["api-catalog-skill"])
        #expect(scoped.first?.description == "From host PromptConfig")
    }

    @Test("listAvailableSkillsForAPI returns empty when skillsFolderPath is nil")
    func apiCatalogEmptyWhenPathUnset() async throws {
        let configuration = HarnessConfigurationSet.Builder()
            .withPromptAssembly(makePromptAssembly(includeAgentSkills: true, skillsFolderPath: nil))
            .build()
        let session = try makeSession(configuration: configuration)
        let conversationID = try await session.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let policy = await session.conversationToolModePolicyRuntimeService

        #expect(try await policy.listAvailableSkillsForAPI(conversationID: conversationID).isEmpty)
        #expect(try await policy.listAvailableSkillsForAPI().isEmpty)
    }

    @Test("listAvailableSkillsForAPI returns empty when includeAgentSkills is false")
    func apiCatalogEmptyWhenIncludeAgentSkillsFalse() async throws {
        let skillsRoot = try makeSkillsDirectory(skills: [
            (name: "hidden-api-skill", description: "Hidden"),
        ])
        let configuration = HarnessConfigurationSet.Builder()
            .withPromptAssembly(makePromptAssembly(includeAgentSkills: false, skillsFolderPath: skillsRoot.path))
            .build()
        let session = try makeSession(configuration: configuration)
        let conversationID = try await session.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let policy = await session.conversationToolModePolicyRuntimeService

        #expect(try await policy.listAvailableSkillsForAPI(conversationID: conversationID).isEmpty)
        #expect(try await policy.listAvailableSkillsForAPI().isEmpty)
    }

    @Test("listAvailableSkillsForAPI filters by mode skills.allow")
    func apiCatalogFiltersByModeAllow() async throws {
        let skillsRoot = try makeSkillsDirectory(skills: [
            (name: "allowed-api-skill", description: "Allowed"),
            (name: "blocked-api-skill", description: "Blocked"),
        ])
        let modeConfig = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "api-skills-allow-only",
                    extends: "chat",
                    skills: .object([
                        "allow": .array([.string("allowed-api-skill")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let configuration = HarnessConfigurationSet.Builder()
            .withPromptAssembly(makePromptAssembly(includeAgentSkills: true, skillsFolderPath: skillsRoot.path))
            .withModeProfiles(modeConfig)
            .build()
        let modeRegistry = ModeRegistryTestSupport.makePort(
            seedingBuiltIns: true,
            modeProfileConfiguration: modeConfig
        )
        let session = try makeSession(configuration: configuration, modeRegistry: modeRegistry)
        let conversationID = try await session.createConversation(
            with: makeModel(),
            userSystemPrompt: "sys",
            modeProfileID: "api-skills-allow-only"
        )
        let policy = await session.conversationToolModePolicyRuntimeService

        let scoped = try await policy.listAvailableSkillsForAPI(conversationID: conversationID)
        #expect(scoped.map(\.name) == ["allowed-api-skill"])
    }
}
