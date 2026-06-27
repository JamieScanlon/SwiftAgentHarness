import Foundation

public enum ProviderRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var registrations: [ProviderID: ProviderRegistration] = [:]
    private nonisolated(unsafe) static var bootstrapped = false

    public static func register(_ registration: ProviderRegistration) {
        lock.lock()
        defer { lock.unlock() }
        registerUnlocked(registration)
    }

    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        registrations = [:]
        bootstrapped = false
    }

    public static func bootstrapBuiltInsIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !bootstrapped else { return }
        bootstrapped = true
        registerUnlocked(ProviderRegistration(
            manifest: ProviderManifests.openai,
            textInference: OpenAITextInferenceProvider()
        ))
        registerUnlocked(ProviderRegistration(
            manifest: ProviderManifests.anthropic,
            textInference: AnthropicTextInferenceProvider()
        ))
        registerUnlocked(ProviderRegistration(
            manifest: ProviderManifests.ollama,
            textInference: OllamaTextInferenceProvider()
        ))
        registerUnlocked(ProviderRegistration(
            manifest: ProviderManifests.lmstudio,
            textInference: LMStudioTextInferenceProvider()
        ))
        registerUnlocked(ProviderRegistration(
            manifest: ProviderManifests.openrouter,
            textInference: OpenRouterTextInferenceProvider()
        ))
    }

    private static func registerUnlocked(_ registration: ProviderRegistration) {
        if registrations[registration.manifest.id] != nil {
            fatalError("Duplicate provider registration: \(registration.manifest.id)")
        }
        registrations[registration.manifest.id] = registration
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

    public static func inspect() -> [ProviderManifest] {
        ProviderManifestValidation.inspect(allManifests())
    }
}
