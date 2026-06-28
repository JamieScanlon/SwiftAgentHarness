import Foundation

public enum ProviderLifecycleState: String, Sendable, Codable {
    case available
    case registered
    case disabled
}

public enum ProviderLifecycle {
    private nonisolated(unsafe) static var disabledProviderIDs: Set<ProviderID> = []
    private static let lock = NSLock()

    public static func setDisabled(_ providerID: ProviderID, disabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if disabled {
            disabledProviderIDs.insert(providerID)
        } else {
            disabledProviderIDs.remove(providerID)
        }
    }

    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        disabledProviderIDs = []
    }

    public static func isDisabled(_ providerID: ProviderID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabledProviderIDs.contains(providerID)
    }

    public static func lifecycleState(
        for manifest: ProviderManifest,
        authStore: AuthProfileStore
    ) -> ProviderLifecycleState {
        if isDisabled(manifest.id) {
            return .disabled
        }
        if hasActiveRegistration(manifest: manifest, authStore: authStore) {
            return .registered
        }
        return .available
    }

    public static func hasActiveRegistration(
        manifest: ProviderManifest,
        authStore: AuthProfileStore
    ) -> Bool {
        if manifest.providerAuthChoices.isEmpty {
            return hasLocalProfile(providerID: manifest.id, authStore: authStore)
        }
        return hasCredentialProfile(providerID: manifest.id, authStore: authStore)
    }

    private static func hasCredentialProfile(providerID: ProviderID, authStore: AuthProfileStore) -> Bool {
        (try? authStore.resolveCredentialPool(providerID: providerID))?.isEmpty == false
    }

    private static func hasLocalProfile(providerID: ProviderID, authStore: AuthProfileStore) -> Bool {
        guard let pool = try? authStore.resolveCredentialPool(providerID: providerID) else { return false }
        return pool.contains { $0.authType == .local && $0.isDispatchReady }
    }
}
