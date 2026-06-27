import Foundation

public struct ProviderSlotInspectEntry: Sendable, Equatable {
    public var providerID: ProviderID
    public var declaredSlots: [ProviderCapabilitySlot]
    public var registeredSlots: Set<ProviderCapabilitySlot>
    public var cliBackendIDs: [String]
    public var registeredCLIBackendIDs: [String]

    public init(
        providerID: ProviderID,
        declaredSlots: [ProviderCapabilitySlot],
        registeredSlots: Set<ProviderCapabilitySlot>,
        cliBackendIDs: [String],
        registeredCLIBackendIDs: [String]
    ) {
        self.providerID = providerID
        self.declaredSlots = declaredSlots
        self.registeredSlots = registeredSlots
        self.cliBackendIDs = cliBackendIDs
        self.registeredCLIBackendIDs = registeredCLIBackendIDs
    }
}

public enum ProviderRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var registrations: [ProviderID: ProviderRegistration] = [:]
    private nonisolated(unsafe) static var cliBackendIndex: [String: any CLIInferenceBackendProviding] = [:]
    private nonisolated(unsafe) static var slotIndex: [ProviderCapabilitySlot: [(ProviderID, any Sendable)]] = [:]
    private nonisolated(unsafe) static var bootstrapped = false

    public static func register(_ registration: ProviderRegistration) throws {
        lock.lock()
        defer { lock.unlock() }
        try registerUnlocked(registration)
    }

    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        registrations = [:]
        cliBackendIndex = [:]
        slotIndex = [:]
        bootstrapped = false
    }

    public static func bootstrapBuiltInsIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !bootstrapped else { return }
        bootstrapped = true

        let openaiManifest = ProviderManifests.openai
        try? registerUnlocked(ProviderRegistration(
            manifest: openaiManifest,
            textInference: OpenAITextInferenceProvider(),
            cliInferenceBackends: [
                StubCLIInferenceBackendProvider(manifest: openaiManifest, cliBackendID: "openai-codex"),
            ],
            speech: StubSpeechProvider(manifest: openaiManifest),
            realtimeVoice: StubRealtimeVoiceProvider(manifest: openaiManifest),
            imageGeneration: StubImageGenerationProvider(manifest: openaiManifest)
        ))

        let anthropicManifest = ProviderManifests.anthropic
        try? registerUnlocked(ProviderRegistration(
            manifest: anthropicManifest,
            textInference: AnthropicTextInferenceProvider(),
            mediaUnderstanding: StubMediaUnderstandingProvider(manifest: anthropicManifest)
        ))

        try? registerUnlocked(ProviderRegistration(
            manifest: ProviderManifests.ollama,
            textInference: OllamaTextInferenceProvider()
        ))
        try? registerUnlocked(ProviderRegistration(
            manifest: ProviderManifests.lmstudio,
            textInference: LMStudioTextInferenceProvider()
        ))
        try? registerUnlocked(ProviderRegistration(
            manifest: ProviderManifests.openrouter,
            textInference: OpenRouterTextInferenceProvider()
        ))
    }

    private static func registerUnlocked(_ registration: ProviderRegistration) throws {
        try ProviderManifestValidation.validateRegistrationConsistency(registration)
        if registrations[registration.manifest.id] != nil {
            fatalError("Duplicate provider registration: \(registration.manifest.id)")
        }
        registrations[registration.manifest.id] = registration
        indexRegistration(registration)
    }

    private static func indexRegistration(_ registration: ProviderRegistration) {
        let providerID = registration.manifest.id
        for backend in registration.cliInferenceBackends {
            let key = cliBackendKey(providerID: providerID, cliBackendID: backend.cliBackendID)
            cliBackendIndex[key] = backend
        }
        for slot in registration.registeredSlots() {
            guard let implementation = registration.implementation(for: slot) else { continue }
            slotIndex[slot, default: []].append((providerID, implementation))
        }
    }

    private static func cliBackendKey(providerID: ProviderID, cliBackendID: String) -> String {
        "\(providerID)/\(cliBackendID)"
    }

    public static func registration(for providerID: ProviderID) throws -> ProviderRegistration {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard let registration = registrations[providerID] else {
            throw ProviderRegistryError.notRegistered(providerID)
        }
        return registration
    }

    public static func manifest(for providerID: ProviderID) throws -> ProviderManifest {
        try registration(for: providerID).manifest
    }

    public static func allManifests() -> [ProviderManifest] {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return registrations.values.map(\.manifest).sorted { $0.id < $1.id }
    }

    public static func allTextInferenceProviders() -> [any TextInferenceProviding] {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return registrations.values.compactMap(\.textInference)
    }

    public static func textInferenceProvider(for providerID: ProviderID) -> (any TextInferenceProviding)? {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return registrations[providerID]?.textInference
    }

    public static func textInferenceProvider(forBinding binding: ProviderBinding) -> (any TextInferenceProviding)? {
        if let byID = textInferenceProvider(for: binding.providerId) {
            return byID
        }
        return allTextInferenceProviders().first { $0.modelProtocol == binding.modelProtocol }
    }

    public static func provider(
        for slot: ProviderCapabilitySlot,
        providerID: ProviderID
    ) throws -> (any Sendable)? {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard let registration = registrations[providerID] else {
            throw ProviderRegistryError.notRegistered(providerID)
        }
        if let implementation = registration.implementation(for: slot) {
            return implementation
        }
        if Set(registration.manifest.capabilitySlots).contains(slot) {
            throw ProviderRegistryError.slotUnavailable(slot, providerID: providerID)
        }
        return nil
    }

    public static func cliInferenceBackend(
        providerID: ProviderID,
        cliBackendID: String
    ) throws -> any CLIInferenceBackendProviding {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard registrations[providerID] != nil else {
            throw ProviderRegistryError.notRegistered(providerID)
        }
        let key = cliBackendKey(providerID: providerID, cliBackendID: cliBackendID)
        guard let backend = cliBackendIndex[key] else {
            throw ProviderRegistryError.cliBackendNotFound(providerID: providerID, cliBackendID: cliBackendID)
        }
        return backend
    }

    public static func allCLIInferenceBackends() -> [any CLIInferenceBackendProviding] {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return Array(cliBackendIndex.values)
    }

    public static func registeredSlots(for providerID: ProviderID) throws -> Set<ProviderCapabilitySlot> {
        try registration(for: providerID).registeredSlots()
    }

    public static func allProviders(for slot: ProviderCapabilitySlot) -> [(ProviderID, any Sendable)] {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return slotIndex[slot] ?? []
    }

    public static func inspectSlots() -> [ProviderSlotInspectEntry] {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return registrations.values
            .map { registration in
                ProviderSlotInspectEntry(
                    providerID: registration.manifest.id,
                    declaredSlots: registration.manifest.capabilitySlots,
                    registeredSlots: registration.registeredSlots(),
                    cliBackendIDs: registration.manifest.cliBackends.map(\.id),
                    registeredCLIBackendIDs: registration.registeredCLIBackendIDs
                )
            }
            .sorted { $0.providerID < $1.providerID }
    }

    public static func inspect() -> [ProviderManifest] {
        ProviderManifestValidation.inspect(allManifests())
    }
}
