import Foundation

public protocol ProviderAdapterFactory: Sendable {
    var adapterKind: String { get }
    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration
}

public enum ProviderAdapterFactoryRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var factories: [String: any ProviderAdapterFactory] = [:]

    public static func register(_ factory: any ProviderAdapterFactory) {
        lock.lock()
        defer { lock.unlock() }
        factories[factory.adapterKind] = factory
    }

    public static func factory(for adapterKind: String) -> (any ProviderAdapterFactory)? {
        lock.lock()
        defer { lock.unlock() }
        return factories[adapterKind]
    }

    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        factories = [:]
    }
}
