import Foundation
import Logging
import SwiftAgentHarnessProviders
import Testing
@testable import SwiftAgentHarness

@Suite("Decision provider registration", .serialized)
struct DecisionProviderRegistrationTests {
    private let runtime = DecisionRuntimeConfig(
        providerID: "test-decider",
        label: "Test Decider",
        surface: .systemOne,
        serverURL: URL(string: "https://decider.example")!,
        apiKeyEnvVars: ["TEST_DECIDER_KEY"],
        models: [
            DecisionModelConfig(endpointModelID: "decider-2026-09", family: "decider", compatGroup: "decider", roles: ["gatekeeper"]),
            DecisionModelConfig(endpointModelID: "decider-latest", lifecycle: ModelLifecycle(aliasOf: "decider")),
        ]
    )

    @Test("The decision slot has a stable raw value")
    func slotRawValue() {
        #expect(ProviderCapabilitySlot.decision.rawValue == "decision")
        #expect(ProviderCapabilitySlot(rawValue: "decision") == .decision)
    }

    @Test("Runtime configs produce a decision-only manifest with API-key auth")
    func manifest() throws {
        let manifest = runtime.manifest()
        try ProviderManifestValidation.validate(manifest)
        #expect(manifest.capabilitySlots == [.decision])
        #expect(manifest.providerAuthChoices.first?.envVars == ["TEST_DECIDER_KEY"])
        #expect(manifest.defaultEndpoint?.baseURL.absoluteString == "https://decider.example")
        let local = DecisionRuntimeConfig(
            providerID: "local-decider", label: "Local", serverURL: URL(string: "http://localhost:8080")!, models: []
        )
        #expect(local.isLocal)
        #expect(local.manifest().providerAuthChoices.isEmpty)
    }

    @Test("Runtime configs produce decide rows with stable ids, lifecycle, locality, and roles")
    func registryEntries() {
        let entries = runtime.registryEntries()
        #expect(entries.count == 2)
        let primary = entries[0]
        #expect(primary.supports(.decide))
        #expect(!primary.supports(.generate))
        #expect(primary.profile(for: .decide)?.surface == .systemOne)
        #expect(primary.compatGroup == "decider")
        #expect(primary.roles == ["gatekeeper"])
        #expect(primary.locality == .vendor)
        #expect(primary.canonicalModelKey == "test-decider/decider-2026-09")
        #expect(entries[1].lifecycle.aliasOf == "decider")
        #expect(runtime.registryEntries()[0].id == primary.id)
        #expect(entries[0].id != entries[1].id)

        let openAI = DecisionRuntimeConfig(
            providerID: "oa", label: "OA", surface: .openAIDecisions,
            serverURL: URL(string: "https://api.openai.com/v1")!, apiKeyEnvVars: ["OPENAI_API_KEY"],
            models: [DecisionModelConfig(endpointModelID: "gpt-decide-1")]
        )
        #expect(openAI.registryEntries()[0].profile(for: .decide)?.surface == .openAIDecisions)
    }

    @Test("Registering a decision provider exposes it through the slot and lifecycle-gated listing")
    func registryLookup() throws {
        try ProviderTestManifestSupport.withRegistryIsolation {
            ProviderRegistry.resetForTesting()
            try ProviderRegistry.register(runtime.registration(transport: MockDecisionTransport([])))
            ProviderRegistry.markBootstrapCompleteForTesting()

            #expect(try ProviderRegistry.registeredSlots(for: "test-decider") == [.decision])
            #expect(ProviderRegistry.decisionProvider(for: "test-decider")?.manifest.id == "test-decider")
            #expect(try ProviderRegistry.provider(for: .decision, providerID: "test-decider") != nil)
            #expect(ProviderRegistry.allProviders(for: .decision).map(\.0) == ["test-decider"])
            #expect(ProviderRegistry.textInferenceProvider(for: "test-decider") == nil)

            let withoutKey = AuthProfileStore(environment: [:])
            let withKey = AuthProfileStore(environment: ["TEST_DECIDER_KEY": "sk-test"])
            #expect(ProviderRegistry.registeredDecisionProviders(authStore: withoutKey).isEmpty)
            #expect(ProviderRegistry.registeredDecisionProviders(authStore: withKey).map(\.manifest.id) == ["test-decider"])
        }
    }

    @Test("Registering a decision implementation without declaring the slot is rejected")
    func undeclaredSlot() throws {
        try ProviderTestManifestSupport.withRegistryIsolation {
            ProviderRegistry.resetForTesting()
            var manifest = runtime.manifest()
            manifest.capabilitySlots = [.textInference]
            let provider = runtime.makeProvider(transport: MockDecisionTransport([]))
            #expect(throws: ProviderManifestValidationError.undeclaredSlotRegistration(.decision, providerID: "test-decider")) {
                try ProviderRegistry.register(ProviderRegistration(manifest: manifest, decision: provider))
            }
        }
    }

    @Test("registerDefaults accepts host decision runtimes")
    func registerDefaultsWithDeciders() {
        ProviderTestManifestSupport.withRegistryIsolation {
            ProviderRegistry.resetForTesting()
            ProviderLifecycle.resetForTesting()
            ProviderAdapterFactoryRegistry.resetForTesting()
            registerDefaults(options: DefaultProviderOptions(installBootstrapHook: false, decisionRuntimes: [runtime]))
            ProviderRegistry.markBootstrapCompleteForTesting()
            #expect(ProviderRegistry.decisionProvider(for: "test-decider") != nil)
            #expect(ProviderRegistry.textInferenceProvider(for: "openai") != nil)
        }
    }
}

@Suite("ModelManager contract integration")
struct ModelManagerContractIntegrationTests {
    private func manager(decide entries: [ModelRegistryEntry]) -> ModelManager {
        ModelManager(
            authProfileStore: AuthProfileStore(environment: [:]),
            contractEntryDiscovery: { _, _ in entries }
        )
    }

    @Test("Decide rows join the registry but stay out of every chat-shaped surface")
    func decideRowsAreContractOnly() async throws {
        let decider = DecisionFixtures.decider("decider-2026-09")
        let manager = manager(decide: [decider])

        let all = await manager.allContractEntries()
        #expect(all.contains { $0.id == decider.id })
        #expect(await manager.getAvailableModels().allSatisfy { $0.id != decider.id })
        #expect(await manager.getRegistryEntries().allSatisfy { $0.id != decider.id })
        await #expect(throws: ModelPoolError.self) { try await manager.resolve(.id(decider.id)) }
        await #expect(throws: ModelPoolError.self) { try await manager.resolve(.slug("decider-2026-09")) }
        #expect(try await manager.resolveAll(.query(ModelQuery())).allSatisfy { $0.id != decider.id })
    }

    @Test("The dispatcher can select from ModelManager as its candidate source")
    func dispatcherOverModelManager() async {
        let decider = DecisionFixtures.decider("decider-2026-09")
        let pool = ModelPoolDecisionDispatcher(
            candidates: manager(decide: [decider]),
            providers: StaticDecisionProviderResolver(["decider": FakeDecisionProvider.constant(providerID: "decider", pYes: 0.93)]),
            roles: RoleBindingResolver(settings: [.memoryGate: RoleBinding(role: .memoryGate, contract: .decide)])
        )
        let outcome = await pool.decide(
            DecisionFixtures.yesNoRequest(["durable"]),
            role: .memoryGate,
            policy: DecisionFixtures.gatePolicy(versions: ["decider-2026-09"], question: "durable")
        )
        #expect(outcome.verdict == .act)
        #expect(outcome.receipt.resolved?.bindingID == "decider/decider-2026-09")
    }
}
