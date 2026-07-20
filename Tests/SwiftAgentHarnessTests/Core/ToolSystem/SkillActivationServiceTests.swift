import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SkillActivationService")
struct SkillActivationServiceTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .ollama,
            modelName: "skill-activation:test",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
    }

    private func makeSkillsDirectory(skills: [(name: String, description: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-activation-\(UUID().uuidString)", isDirectory: true)
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

    private func makeDependencies(
        container: ModelContainer,
        configurationSet: HarnessConfigurationSet = .lockedDownBaseline,
        modeRegistry: any ModeRegistryAccessing = ModeRegistryTestSupport.makePort()
    ) -> ConversationRuntimeDependencies {
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        return ConversationRuntimeDependencies(
            persistenceDomain: domain,
            compactionCoordinator: CompactionConcurrencyCoordinator(),
            contextEngine: DefaultContextEngine(compactionCoordinator: CompactionConcurrencyCoordinator(), logger: nil),
            contextAssemblyRuntime: ContextAssemblyRuntimeFacade(
                persistenceDomain: domain,
                conversationTransformConfiguration: .default
            ),
            modeRegistry: modeRegistry,
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            runtimeLaneCoordinator: RuntimeLaneCoordinator(configuration: .default),
            configurationSet: configurationSet,
            toolPolicy: .unrestricted,
            trustPolicyConfiguration: .disabled,
            agentHarness: .default,
            thinkingPolicyConfiguration: .default,
            conversationTransformConfiguration: .default,
            conversationTransformer: NoOpConversationTransformer(),
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal,
            logger: nil
        )
    }

    private func registerConversation(
        model: Model,
        activatedSkillNames: [String],
        domain: ConversationPersistenceDomain,
        modeProfileID: String? = nil
    ) async throws -> UUID {
        let metadata = ConversationMetadataActivatedSkills.mergingActivatedAgentSkillNames(
            Set(activatedSkillNames),
            into: nil
        )
        let conversation = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: metadata,
            interactionMode: .chat,
            modeProfileID: modeProfileID
        )
        return conversation.id
    }

    private func makeService(deps: ConversationRuntimeDependencies) async -> SkillActivationService {
        let service = SkillActivationService(deps: deps)
        await service.testing_setIncludeAgentSkillsOverride(true)
        await service.testing_setSkillsDirectoryURLOverride(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        return service
    }

    @Test("skillLoader(for:) keeps activated skills isolated per conversation")
    func perConversationLoaderIsolation() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let service = await makeService(deps: deps)
        let model = makeModel()
        let idA = try await registerConversation(
            model: model,
            activatedSkillNames: ["skill-a"],
            domain: deps.persistenceDomain
        )
        let idB = try await registerConversation(
            model: model,
            activatedSkillNames: ["skill-b"],
            domain: deps.persistenceDomain
        )

        let loaderA = try #require(await service.skillLoader(for: idA))
        let loaderB = try #require(await service.skillLoader(for: idB))

        await loaderA.activateSkill(named: "only-a")
        await loaderB.activateSkill(named: "only-b")

        #expect(await loaderA.activatedSkills == Set(["only-a"]))
        #expect(await loaderB.activatedSkills == Set(["only-b"]))
    }

    @Test("restoreSkillLoader on one conversation does not clear another conversation loader")
    func restoreDoesNotClearOtherConversation() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let service = await makeService(deps: deps)
        let model = makeModel()
        let idA = try await registerConversation(
            model: model,
            activatedSkillNames: ["skill-a"],
            domain: deps.persistenceDomain
        )
        let idB = try await registerConversation(
            model: model,
            activatedSkillNames: ["skill-b"],
            domain: deps.persistenceDomain
        )

        let loaderA = try #require(await service.skillLoader(for: idA))
        await loaderA.activateSkill(named: "keep-on-a")

        try await service.restoreSkillLoader(for: idB)

        #expect(await loaderA.activatedSkills == Set(["keep-on-a"]))
    }

    @Test("concurrent restoreSkillLoader on one conversation does not clear another")
    func concurrentRestoreIsolation() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let service = await makeService(deps: deps)
        let model = makeModel()
        let idA = try await registerConversation(
            model: model,
            activatedSkillNames: ["skill-a"],
            domain: deps.persistenceDomain
        )
        let idB = try await registerConversation(
            model: model,
            activatedSkillNames: ["skill-b"],
            domain: deps.persistenceDomain
        )

        let loaderA = try #require(await service.skillLoader(for: idA))
        await loaderA.activateSkill(named: "keep-on-a")

        async let restoreB: Void = try await service.restoreSkillLoader(for: idB)
        try await restoreB

        #expect(await loaderA.activatedSkills == Set(["keep-on-a"]))
    }

    @Test("listAvailableSkillsForSlash reads skillsFolderPath from configurationSet")
    func slashCatalogUsesLoadedSkillsFolderPath() async throws {
        let skillsRoot = try makeSkillsDirectory(skills: [
            (name: "catalog-skill", description: "A catalog skill"),
        ])
        let configurationSet = HarnessConfigurationSet.Builder()
            .withPromptAssembly(makePromptAssembly(includeAgentSkills: true, skillsFolderPath: skillsRoot.path))
            .build()
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container, configurationSet: configurationSet)
        let service = SkillActivationService(deps: deps)
        let conversationID = try await registerConversation(
            model: makeModel(),
            activatedSkillNames: [],
            domain: deps.persistenceDomain
        )

        let skills = try await service.listAvailableSkillsForSlash(conversationID: conversationID)
        #expect(skills.map(\.name) == ["catalog-skill"])
        #expect(skills.first?.description == "A catalog skill")
    }

    @Test("listAvailableSkillsForSlash returns empty when skillsFolderPath is nil")
    func slashCatalogEmptyWhenPathUnset() async throws {
        let configurationSet = HarnessConfigurationSet.Builder()
            .withPromptAssembly(makePromptAssembly(includeAgentSkills: true, skillsFolderPath: nil))
            .build()
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container, configurationSet: configurationSet)
        let service = SkillActivationService(deps: deps)
        let conversationID = try await registerConversation(
            model: makeModel(),
            activatedSkillNames: [],
            domain: deps.persistenceDomain
        )

        let skills = try await service.listAvailableSkillsForSlash(conversationID: conversationID)
        #expect(skills.isEmpty)
        #expect(await service.skillLoader(for: conversationID) == nil)
    }

    @Test("listAvailableSkillsForSlash returns empty when includeAgentSkills is false")
    func slashCatalogEmptyWhenIncludeAgentSkillsFalse() async throws {
        let skillsRoot = try makeSkillsDirectory(skills: [
            (name: "hidden-skill", description: "Should stay hidden"),
        ])
        let configurationSet = HarnessConfigurationSet.Builder()
            .withPromptAssembly(makePromptAssembly(includeAgentSkills: false, skillsFolderPath: skillsRoot.path))
            .build()
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container, configurationSet: configurationSet)
        let service = SkillActivationService(deps: deps)
        let conversationID = try await registerConversation(
            model: makeModel(),
            activatedSkillNames: [],
            domain: deps.persistenceDomain
        )

        let skills = try await service.listAvailableSkillsForSlash(conversationID: conversationID)
        #expect(skills.isEmpty)
    }

    @Test("listAvailableSkillsForSlash filters by mode skills.allow")
    func slashCatalogFiltersByModeAllow() async throws {
        let skillsRoot = try makeSkillsDirectory(skills: [
            (name: "allowed-skill", description: "Allowed"),
            (name: "blocked-skill", description: "Blocked"),
        ])
        let modeConfig = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "skills-allow-only",
                    extends: "chat",
                    skills: .object([
                        "allow": .array([.string("allowed-skill")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let configurationSet = HarnessConfigurationSet.Builder()
            .withPromptAssembly(makePromptAssembly(includeAgentSkills: true, skillsFolderPath: skillsRoot.path))
            .withModeProfiles(modeConfig)
            .build()
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(
            container: container,
            configurationSet: configurationSet,
            modeRegistry: ModeRegistryTestSupport.makePort(
                seedingBuiltIns: true,
                modeProfileConfiguration: modeConfig
            )
        )
        let service = SkillActivationService(deps: deps)
        let conversationID = try await registerConversation(
            model: makeModel(),
            activatedSkillNames: [],
            domain: deps.persistenceDomain,
            modeProfileID: "skills-allow-only"
        )

        let skills = try await service.listAvailableSkillsForSlash(conversationID: conversationID)
        #expect(skills.map(\.name) == ["allowed-skill"])
    }
}
