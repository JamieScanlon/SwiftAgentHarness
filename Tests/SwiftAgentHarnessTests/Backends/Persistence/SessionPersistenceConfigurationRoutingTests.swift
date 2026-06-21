import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite(.serialized)
struct SessionPersistenceConfigurationRoutingTests {
    private let keyRoot = "SAH_SESSION_STORE_ROOT"

    @Test func harnessOnDiskV2ConfiguredWhenStoreRootSet() {
        let root = NSTemporaryDirectory() + "sah-v2-root-\(UUID().uuidString)"
        defer {
            unsetenv(keyRoot)
            try? FileManager.default.removeItem(atPath: root)
        }
        setenv(keyRoot, root, 1)

        #expect(SessionPersistenceConfiguration.harnessOnDiskV2Configured)
    }

    @Test func harnessOnDiskV2NotConfiguredWithoutStoreRoot() {
        defer { unsetenv(keyRoot) }
        unsetenv(keyRoot)

        #expect(!SessionPersistenceConfiguration.harnessOnDiskV2Configured)
    }
}
