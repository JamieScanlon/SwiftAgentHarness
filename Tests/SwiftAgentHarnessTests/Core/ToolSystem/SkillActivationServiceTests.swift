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

    private func makeDependencies(container: ModelContainer) -> ConversationRuntimeDependencies {
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        return ConversationRuntimeDependencies(
            persistenceDomain: domain,
            compactionCoordinator: CompactionConcurrencyCoordinator(),
            contextEngine: DefaultContextEngine(compactionCoordinator: CompactionConcurrencyCoordinator(), logger: nil),
            contextAssemblyRuntime: ContextAssemblyRuntimeFacade(
                persistenceDomain: domain,
                conversationTransformConfiguration: .default
            ),
            modeRegistry: ModeRegistryTestSupport.makePort(),
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            runtimeLaneCoordinator: RuntimeLaneCoordinator(configuration: .default),
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
        id: UUID,
        model: Model,
        activatedSkillNames: [String],
        domain: ConversationPersistenceDomain
    ) async {
        var conversation = ModelConversation(id: id, model: model, messages: [], systemPrompt: "sys")
        conversation.metadata = ConversationMetadataActivatedSkills.mergingActivatedAgentSkillNames(
            Set(activatedSkillNames),
            into: nil
        )
        await domain.replaceConversationInRegistry(conversation)
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
        let idA = UUID()
        let idB = UUID()
        await registerConversation(id: idA, model: model, activatedSkillNames: ["skill-a"], domain: deps.persistenceDomain)
        await registerConversation(id: idB, model: model, activatedSkillNames: ["skill-b"], domain: deps.persistenceDomain)

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
        let idA = UUID()
        let idB = UUID()
        await registerConversation(id: idA, model: model, activatedSkillNames: ["skill-a"], domain: deps.persistenceDomain)
        await registerConversation(id: idB, model: model, activatedSkillNames: ["skill-b"], domain: deps.persistenceDomain)

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
        let idA = UUID()
        let idB = UUID()
        await registerConversation(id: idA, model: model, activatedSkillNames: ["skill-a"], domain: deps.persistenceDomain)
        await registerConversation(id: idB, model: model, activatedSkillNames: ["skill-b"], domain: deps.persistenceDomain)

        let loaderA = try #require(await service.skillLoader(for: idA))
        await loaderA.activateSkill(named: "keep-on-a")

        async let restoreB: Void = try await service.restoreSkillLoader(for: idB)
        try await restoreB

        #expect(await loaderA.activatedSkills == Set(["keep-on-a"]))
    }
}
