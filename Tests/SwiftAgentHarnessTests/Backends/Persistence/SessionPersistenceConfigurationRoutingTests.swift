import Foundation
import Testing
@testable import SwiftAgentHarness

struct SessionPersistenceConfigurationRoutingTests {
    private let keyRoot = "SAH_SESSION_STORE_ROOT"

    @Test func harnessOnDiskV2ConfiguredWhenStoreRootSet() {
        let root = NSTemporaryDirectory() + "sah-v2-root-\(UUID().uuidString)"
        HarnessEnvironmentOverride.$overrides.withValue([keyRoot: root]) {
            #expect(SessionPersistenceConfiguration.harnessOnDiskV2Configured)
        }
    }

    @Test func harnessOnDiskV2NotConfiguredWithoutStoreRoot() {
        HarnessEnvironmentOverride.$overrides.withValue([:]) {
            #expect(!SessionPersistenceConfiguration.harnessOnDiskV2Configured)
        }
    }
}
