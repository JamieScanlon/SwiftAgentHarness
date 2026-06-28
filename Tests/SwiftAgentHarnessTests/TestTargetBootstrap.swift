import SwiftAgentHarnessProviders

/// Registers bundled providers once when the test bundle loads so tests that rely on
/// `ProviderRegistry.ensureBootstrapped()` do not need per-suite setup.
private enum TestTargetBootstrap {
    static let activated: Void = {
        bootstrap()
    }()
}

private let _testTargetBootstrap: Void = TestTargetBootstrap.activated
