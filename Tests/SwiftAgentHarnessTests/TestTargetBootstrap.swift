import SwiftAgentHarness
import SwiftAgentHarnessProviders

/// Registers bundled providers once when the test bundle loads so tests that rely on
/// `ProviderRegistry.ensureBootstrapped()` do not need per-suite setup.
public enum TestTargetBootstrap {
    public static func ensureProvidersRegistered() {
        ProviderTestSupport.registerDefaultsForTesting(
            inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
        )
    }
}

/// Keeps ``TestTargetBootstrap`` linked so module-load registration is not dead-stripped.
public enum TestTargetBootstrapGate {
    public static let linked: Bool = {
        TestTargetBootstrap.ensureProvidersRegistered()
        return true
    }()
}

/// Referenced from ``PublicAPISurfaceTests`` so bootstrap is never dead-stripped.
let testTargetBootstrapGate: Bool = TestTargetBootstrapGate.linked
