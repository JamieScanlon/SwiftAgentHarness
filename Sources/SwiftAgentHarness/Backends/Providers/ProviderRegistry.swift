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
    private enum BootstrapPhase: Equatable {
        case idle
        case running
        case complete
    }

    private static let lock = NSLock()
    private static let accessLock = NSRecursiveLock()
    private static let bootstrapCondition = NSCondition()
    private nonisolated(unsafe) static var registrations: [ProviderID: ProviderRegistration] = [:]
    private nonisolated(unsafe) static var cliBackendIndex: [String: any CLIInferenceBackendProviding] = [:]
    private nonisolated(unsafe) static var slotIndex: [ProviderCapabilitySlot: [(ProviderID, any Sendable)]] = [:]
    private nonisolated(unsafe) static var bootstrapPhase: BootstrapPhase = .idle
    private nonisolated(unsafe) static var bootstrapThread: Thread?
    private nonisolated(unsafe) static var bootstrapHook: (@Sendable () -> Void)?

    public static func installBootstrap(_ hook: @escaping @Sendable () -> Void) {
        withRegistryAccess {
            lock.lock()
            defer { lock.unlock() }
            bootstrapHook = hook
        }
    }

    public static func withExclusiveRegistryAccess<R>(_ body: () throws -> R) rethrows -> R {
        try withRegistryAccess(body)
    }

    private static func withRegistryAccess<R>(_ body: () throws -> R) rethrows -> R {
        accessLock.lock()
        defer { accessLock.unlock() }
        return try body()
    }

    public static func ensureBootstrapped() {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
        }
    }

    private static func ensureBootstrappedUnlocked() {
        bootstrapCondition.lock()
        if bootstrapPhase == .complete {
            lock.lock()
            let hasRegistrations = !registrations.isEmpty
            lock.unlock()
            if hasRegistrations {
                bootstrapCondition.unlock()
                return
            }
            bootstrapPhase = .idle
        }
        if bootstrapPhase == .running {
            if bootstrapThread == Thread.current {
                bootstrapCondition.unlock()
                return
            }
            while bootstrapPhase == .running {
                bootstrapCondition.wait()
            }
            bootstrapCondition.unlock()
            return
        }

        bootstrapPhase = .running
        bootstrapThread = Thread.current
        let hook = bootstrapHook
        bootstrapCondition.unlock()
        hook?()
        bootstrapCondition.lock()
        lock.lock()
        let hasRegistrations = !registrations.isEmpty
        lock.unlock()
        bootstrapPhase = hasRegistrations ? .complete : .idle
        bootstrapThread = nil
        bootstrapCondition.broadcast()
        bootstrapCondition.unlock()
    }

    @available(*, deprecated, message: "Use ensureBootstrapped() after installing a bootstrap hook via installBootstrap(_:)")
    public static func bootstrapBuiltInsIfNeeded() {
        ensureBootstrapped()
    }

    public static func register(_ registration: ProviderRegistration) throws {
        try withRegistryAccess {
            lock.lock()
            defer { lock.unlock() }
            try registerUnlocked(registration)
        }
    }

    public static func resetForTesting() {
        withRegistryAccess {
            bootstrapCondition.lock()
            if bootstrapPhase == .running && bootstrapThread != Thread.current {
                while bootstrapPhase == .running {
                    bootstrapCondition.wait()
                }
            }
            bootstrapPhase = .idle
            bootstrapThread = nil
            bootstrapHook = nil
            bootstrapCondition.unlock()

            lock.lock()
            defer { lock.unlock() }
            registrations = [:]
            cliBackendIndex = [:]
            slotIndex = [:]
        }
    }

    private static func registerUnlocked(_ registration: ProviderRegistration) throws {
        try ProviderManifestValidation.validateRegistrationConsistency(registration)
        if registrations[registration.manifest.id] != nil {
            throw ProviderRegistryError.duplicateRegistration(registration.manifest.id)
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
        try withRegistryAccess {
            ensureBootstrappedUnlocked()
            lock.lock()
            defer { lock.unlock() }
            guard let registration = registrations[providerID] else {
                throw ProviderRegistryError.notRegistered(providerID)
            }
            return registration
        }
    }

    public static func manifest(for providerID: ProviderID) throws -> ProviderManifest {
        try registration(for: providerID).manifest
    }

    public static func optionalManifest(for providerID: ProviderID) -> ProviderManifest? {
        try? manifest(for: providerID)
    }

    public static func allManifests() -> [ProviderManifest] {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
            lock.lock()
            defer { lock.unlock() }
            return registrations.values.map(\.manifest).sorted { $0.id < $1.id }
        }
    }

    public static func allTextInferenceProviders() -> [any TextInferenceProviding] {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
            lock.lock()
            defer { lock.unlock() }
            return registrations.values.compactMap(\.textInference)
        }
    }

    public static func registeredTextInferenceProviders(
        authStore: AuthProfileStore
    ) -> [any TextInferenceProviding] {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
            lock.lock()
            let candidates = registrations.values.compactMap { registration -> (ProviderManifest, any TextInferenceProviding)? in
                guard let textInference = registration.textInference else { return nil }
                return (registration.manifest, textInference)
            }
            lock.unlock()
            return candidates.compactMap { manifest, textInference in
                guard ProviderLifecycle.lifecycleState(for: manifest, authStore: authStore) == .registered else {
                    return nil
                }
                return textInference
            }
        }
    }

    public static func manifest(forAlias alias: String) -> ProviderManifest? {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
            let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            lock.lock()
            defer { lock.unlock() }
            return registrations.values.map(\.manifest).first { manifest in
                manifest.id == normalized || manifest.providerAuthAliases.contains(normalized)
            }
        }
    }

    public static func providerID(forAlias alias: String) -> ProviderID? {
        manifest(forAlias: alias)?.id
    }

    public static func textInferenceProvider(for providerID: ProviderID) -> (any TextInferenceProviding)? {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
            lock.lock()
            defer { lock.unlock() }
            return registrations[providerID]?.textInference
        }
    }

    private static func textInferenceProviderUnlocked(forBinding binding: ProviderBinding) -> (any TextInferenceProviding)? {
        if let byID = registrations[binding.providerId]?.textInference {
            return byID
        }
        return registrations.values.compactMap(\.textInference).first { $0.modelProtocol == binding.modelProtocol }
    }

    public static func textInferenceProvider(forBinding binding: ProviderBinding) -> (any TextInferenceProviding)? {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
            lock.lock()
            if let provider = textInferenceProviderUnlocked(forBinding: binding) {
                lock.unlock()
                return provider
            }
            lock.unlock()
            bootstrapCondition.lock()
            bootstrapPhase = .idle
            bootstrapCondition.unlock()
            ensureBootstrappedUnlocked()
            lock.lock()
            defer { lock.unlock() }
            return textInferenceProviderUnlocked(forBinding: binding)
        }
    }

    public static func provider(
        for slot: ProviderCapabilitySlot,
        providerID: ProviderID
    ) throws -> (any Sendable)? {
        try withRegistryAccess {
            ensureBootstrappedUnlocked()
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
    }

    public static func cliInferenceBackend(
        providerID: ProviderID,
        cliBackendID: String
    ) throws -> any CLIInferenceBackendProviding {
        try withRegistryAccess {
            ensureBootstrappedUnlocked()
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
    }

    public static func allCLIInferenceBackends() -> [any CLIInferenceBackendProviding] {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
            lock.lock()
            defer { lock.unlock() }
            return Array(cliBackendIndex.values)
        }
    }

    public static func registeredSlots(for providerID: ProviderID) throws -> Set<ProviderCapabilitySlot> {
        try registration(for: providerID).registeredSlots()
    }

    public static func allProviders(for slot: ProviderCapabilitySlot) -> [(ProviderID, any Sendable)] {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
            lock.lock()
            defer { lock.unlock() }
            return slotIndex[slot] ?? []
        }
    }

    public static func inspectSlots() -> [ProviderSlotInspectEntry] {
        withRegistryAccess {
            ensureBootstrappedUnlocked()
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
    }

    public static func markBootstrapCompleteForTesting() {
        withRegistryAccess {
            bootstrapCondition.lock()
            bootstrapPhase = .complete
            bootstrapThread = nil
            bootstrapCondition.broadcast()
            bootstrapCondition.unlock()
        }
    }

    public static func inspect() -> [ProviderManifest] {
        ProviderManifestValidation.inspect(allManifests())
    }
}

extension ProviderBinding {
    /// Resolves manifest/auth provider id when legacy bindings use ``ModelProtocol`` rawValue as ``providerId``.
    public func canonicalProviderID() -> ProviderID {
        if ProviderRegistry.optionalManifest(for: providerId) != nil {
            return providerId
        }
        ProviderRegistry.ensureBootstrapped()
        return ProviderRegistry.textInferenceProvider(forBinding: self)?.manifest.id ?? providerId
    }
}
