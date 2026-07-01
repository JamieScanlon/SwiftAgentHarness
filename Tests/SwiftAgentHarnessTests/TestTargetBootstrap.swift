import SwiftAgentHarness
import SwiftAgentHarnessProviders

/// Registers bundled providers once when the test bundle loads so tests that rely on
/// `ProviderRegistry.ensureBootstrapped()` do not need per-suite setup.
public enum TestTargetBootstrap {
    public static func ensureProvidersRegistered() {
        ProviderResourceBundle.setResourceBundle(SwiftAgentHarnessProvidersResources.bundle)
        if !ProviderRegistry.allManifests().isEmpty {
            return
        }
        bootstrap()
        if ProviderRegistry.allManifests().isEmpty {
            ProviderTestSupport.registerDefaultsForTesting()
        }
    }
}

/// Keeps ``TestTargetBootstrap`` linked so module-load registration is not dead-stripped.
public enum TestTargetBootstrapGate {
    public static let linked: Bool = {
        TestTargetBootstrap.ensureProvidersRegistered()
        return true
    }()
}

private let _testTargetBootstrapGate: Bool = TestTargetBootstrapGate.linked
