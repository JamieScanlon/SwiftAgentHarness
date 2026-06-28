import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("ProviderLifecycle")
struct ProviderLifecycleTests {
    @Test("Credential provider is available without auth profile")
    func credentialProviderAvailableWithoutAuth() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "anthropic")
        let store = AuthProfileStore(environment: [:])
        #expect(ProviderLifecycle.lifecycleState(for: manifest, authStore: store) == .available)
    }

    @Test("Credential provider is registered with auth profile")
    func credentialProviderRegisteredWithAuth() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "anthropic")
        let store = AuthProfileStore(
            environment: [:],
            seedProfiles: [
                AuthProfile(id: "test", providerID: "anthropic", authType: .apiKey, apiKey: "sk-test"),
            ]
        )
        #expect(ProviderLifecycle.lifecycleState(for: manifest, authStore: store) == .registered)
    }

    @Test("Local provider requires explicit local profile")
    func localProviderRequiresLocalProfile() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "ollama")
        let emptyStore = AuthProfileStore(environment: [:])
        #expect(ProviderLifecycle.lifecycleState(for: manifest, authStore: emptyStore) == .available)

        let registeredStore = AuthProfileStore(
            environment: [:],
            seedProfiles: [
                AuthProfile(
                    id: "local",
                    providerID: "ollama",
                    authType: .local,
                    baseURL: Constants.ollamaServerURL
                ),
            ]
        )
        #expect(ProviderLifecycle.lifecycleState(for: manifest, authStore: registeredStore) == .registered)
    }

    @Test("Disabled provider stays disabled even with credentials")
    func disabledOverridesRegistered() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "openai")
        let store = AuthProfileStore(
            environment: [:],
            seedProfiles: [
                AuthProfile(id: "test", providerID: "openai", authType: .apiKey, apiKey: "sk-test"),
            ]
        )
        ProviderLifecycle.setDisabled("openai", disabled: true)
        defer { ProviderLifecycle.setDisabled("openai", disabled: false) }
        #expect(ProviderLifecycle.lifecycleState(for: manifest, authStore: store) == .disabled)
    }
}

@Suite("ModelManager lifecycle gate")
struct ModelManagerLifecycleGateTests {
    @Test("Empty auth store yields empty registry after discovery")
    func emptyAuthYieldsEmptyRegistry() async {
        ProviderTestManifestSupport.prepareRegistry()
        let manager = ModelManager(authProfileStore: AuthProfileStore(environment: [:]))
        let entries = await manager.getRegistryEntries()
        #expect(entries.isEmpty)
    }

    @Test("Seeded auth profiles enable static-catalog discovery")
    func seededAuthEnablesDiscovery() async {
        ProviderTestManifestSupport.prepareRegistry()
        let manager = ModelManager(
            authProfileStore: ProviderTestSupport.authStoreWithAllProvidersRegistered()
        )
        let entries = await manager.getRegistryEntries()
        #expect(!entries.isEmpty)
        #expect(entries.contains { $0.providers.contains { $0.providerId == "anthropic" } })
        #expect(entries.contains { $0.providers.contains { $0.providerId == "openai" } })
    }
}

@Suite("ConfigPluginLoader", .serialized)
struct ConfigPluginLoaderTests {
    @Test("Decodes and registers openai-compat config plugin")
    func loadsConfigPlugin() throws {
        ProviderRegistry.resetForTesting()
        ProviderAdapterFactoryRegistry.resetForTesting()
        DefaultProviderAdapterFactories.installAll()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("llamacpp-local.providerconfig.json")
        let json = """
        {
          "schemaVersion": 1,
          "adapterKind": "openai-compat",
          "id": "llamacpp-local",
          "label": "llama.cpp (local)",
          "providerEndpoints": [{ "id": "default", "baseUrl": "http://127.0.0.1:8080/v1" }],
          "providerAuthChoices": [],
          "modelSupport": { "modelPrefixes": [] },
          "capabilitySlots": ["text-inference"]
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let loaded = try ConfigPluginLoader.loadAll(from: dir)
        #expect(loaded == ["llamacpp-local"])
        #expect(ProviderRegistry.textInferenceProvider(for: "llamacpp-local") != nil)
    }

    @Test("Rejects duplicate provider id")
    func rejectsDuplicateID() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("openai-dup.providerconfig.json")
        let json = """
        {
          "schemaVersion": 1,
          "adapterKind": "openai-compat",
          "id": "openai",
          "label": "Duplicate OpenAI",
          "providerEndpoints": [{ "id": "default", "baseUrl": "http://127.0.0.1:8080/v1" }],
          "providerAuthChoices": [],
          "modelSupport": { "modelPrefixes": [] },
          "capabilitySlots": ["text-inference"]
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        #expect(throws: ProviderInstanceConfigError.duplicateProviderID("openai")) {
            ProviderTestManifestSupport.prepareRegistry()
            try ConfigPluginLoader.load(from: configURL)
        }
    }

    @Test("Rejects unknown adapter kind")
    func rejectsUnknownAdapterKind() throws {
        ProviderTestManifestSupport.prepareRegistry()
        ProviderAdapterFactoryRegistry.resetForTesting()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("unknown.providerconfig.json")
        let json = """
        {
          "schemaVersion": 1,
          "adapterKind": "unknown-kind",
          "id": "custom",
          "label": "Custom",
          "providerEndpoints": [{ "id": "default", "baseUrl": "http://127.0.0.1:8080/v1" }],
          "providerAuthChoices": [],
          "modelSupport": { "modelPrefixes": [] },
          "capabilitySlots": ["text-inference"]
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        #expect(throws: ProviderInstanceConfigError.unknownAdapterKind("unknown-kind")) {
            try ConfigPluginLoader.load(from: configURL)
        }
    }
}
