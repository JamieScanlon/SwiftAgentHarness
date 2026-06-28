import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("Provider slot registration")
struct ProviderSlotRegistrationTests {
    @Test("OpenAI bootstrap registers declared non-text stubs")
    func openAIBootstrapRegistersStubs() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let slots = try ProviderRegistry.registeredSlots(for: "openai")
        #expect(slots.contains(.textInference))
        #expect(slots.contains(.cliInferenceBackend))
        #expect(slots.contains(.speech))
        #expect(slots.contains(.imageGeneration))
        #expect(slots.contains(.realtimeVoice))
    }

    @Test("CLI backend lookup resolves openai-codex stub")
    func cliBackendLookup() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let backend = try ProviderRegistry.cliInferenceBackend(providerID: "openai", cliBackendID: "openai-codex")
        #expect(backend.cliBackendID == "openai-codex")
        #expect(backend.manifest.id == "openai")
    }

    @Test("CLI backend lookup throws when missing")
    func cliBackendNotFound() {
        ProviderTestManifestSupport.prepareRegistry()
        #expect(throws: ProviderRegistryError.self) {
            try ProviderRegistry.cliInferenceBackend(providerID: "openai", cliBackendID: "missing")
        }
    }

    @Test("Declared slot without registration throws slotUnavailable")
    func slotUnavailableWhenDeclaredButMissing() throws {
        ProviderRegistry.resetForTesting()
        let manifest = ProviderManifest(
            id: "partial",
            label: "Partial",
            providerEndpoints: [
                ProviderEndpoint(id: "partial-default", baseURL: URL(string: "https://partial.example/v1")!),
            ],
            providerAuthChoices: [
                ProviderAuthChoice(id: "api-key", label: "Key", envVars: ["PARTIAL_KEY"]),
            ],
            modelSupport: ProviderModelSupport(modelPrefixes: ["partial-"]),
            capabilitySlots: [.textInference, .speech]
        )
        try ProviderRegistry.register(
            ProviderRegistration(
                manifest: manifest,
                textInference: OpenAITextInferenceProvider(manifest: manifest)
            )
        )
        #expect(throws: ProviderRegistryError.self) {
            _ = try ProviderRegistry.provider(for: .speech, providerID: "partial")
        }
    }

    @Test("Undeclared slot registration is rejected")
    func undeclaredSlotRegistrationRejected() throws {
        ProviderRegistry.resetForTesting()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "ollama")
        #expect(throws: ProviderManifestValidationError.self) {
            try ProviderRegistry.register(
                ProviderRegistration(
                    manifest: manifest,
                    textInference: OllamaTextInferenceProvider(manifest: manifest),
                    speech: StubSpeechProvider(manifest: manifest)
                )
            )
        }
    }

    @Test("Missing CLI backend registration is rejected when slot declared")
    func missingCLIBackendRegistrationRejected() throws {
        ProviderRegistry.resetForTesting()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "openai")
        #expect(throws: ProviderManifestValidationError.self) {
            try ProviderRegistry.register(
                ProviderRegistration(
                    manifest: manifest,
                    textInference: OpenAITextInferenceProvider(manifest: manifest),
                    cliInferenceBackends: []
                )
            )
        }
    }

    @Test("ProviderSlotRuntimeHooks delegates to registry")
    func slotRuntimeHooksDelegate() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let backend = try ProviderSlotRuntimeHooks.cliInferenceBackend(
            providerID: "openai",
            cliBackendID: "openai-codex"
        )
        #expect(backend.cliBackendID == "openai-codex")
        let speech = try ProviderSlotRuntimeHooks.provider(for: .speech, providerID: "openai")
        #expect(speech is StubSpeechProvider)
    }

    @Test("inspectSlots reports declared vs registered matrix")
    func inspectSlotsSnapshot() {
        ProviderTestManifestSupport.prepareRegistry()
        let entries = ProviderRegistry.inspectSlots()
        let openai = entries.first { $0.providerID == "openai" }
        #expect(openai != nil)
        #expect(openai?.declaredSlots.contains(.speech) == true)
        #expect(openai?.registeredSlots.contains(.speech) == true)
        #expect(openai?.cliBackendIDs.contains("openai-codex") == true)
        #expect(openai?.registeredCLIBackendIDs.contains("openai-codex") == true)

        let anthropic = entries.first { $0.providerID == "anthropic" }
        #expect(anthropic?.registeredSlots.contains(.mediaUnderstanding) == true)
    }
}

@Suite("Provider slot manifest validation")
struct ProviderSlotManifestValidationTests {
    @Test("Duplicate cliBackend id in manifest is rejected")
    func duplicateCLIBackendIDRejected() {
        let manifest = ProviderManifest(
            id: "dup-cli",
            label: "Dup CLI",
            providerEndpoints: [
                ProviderEndpoint(id: "dup-default", baseURL: URL(string: "https://dup.example/v1")!),
            ],
            providerAuthChoices: [
                ProviderAuthChoice(id: "api-key", label: "Key", envVars: ["DUP_KEY"]),
            ],
            modelSupport: ProviderModelSupport(modelPrefixes: []),
            cliBackends: [
                ProviderCLIBackend(id: "same-id", label: "A"),
                ProviderCLIBackend(id: "same-id", label: "B"),
            ],
            capabilitySlots: [.textInference, .cliInferenceBackend]
        )
        #expect(throws: ProviderManifestValidationError.self) {
            try ProviderManifestValidation.validate(manifest)
        }
    }

    @Test("cliInferenceBackend slot without cliBackends is rejected")
    func cliSlotWithoutBackendsRejected() {
        let manifest = ProviderManifest(
            id: "cli-empty",
            label: "CLI Empty",
            providerEndpoints: [
                ProviderEndpoint(id: "cli-empty-default", baseURL: URL(string: "https://cli.example/v1")!),
            ],
            providerAuthChoices: [
                ProviderAuthChoice(id: "api-key", label: "Key", envVars: ["CLI_KEY"]),
            ],
            modelSupport: ProviderModelSupport(modelPrefixes: []),
            cliBackends: [],
            capabilitySlots: [.textInference, .cliInferenceBackend]
        )
        #expect(throws: ProviderManifestValidationError.self) {
            try ProviderManifestValidation.validate(manifest)
        }
    }
}
