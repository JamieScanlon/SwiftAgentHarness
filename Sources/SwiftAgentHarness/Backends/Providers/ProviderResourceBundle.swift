import Foundation

/// Bundle carrying provider manifest and catalog JSON resources.
/// Set by ``SwiftAgentHarnessProviders/registerDefaults()`` before registry bootstrap.
public enum ProviderResourceBundle {
    private nonisolated(unsafe) static var bundle: Bundle = .module

    public static var resourceBundle: Bundle { bundle }

    public static func setResourceBundle(_ bundle: Bundle) {
        self.bundle = bundle
    }
}
