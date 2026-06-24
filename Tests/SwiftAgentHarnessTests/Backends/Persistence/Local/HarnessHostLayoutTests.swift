import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessHostLayout")
struct HarnessHostLayoutTests {
    @Test("sandbox registry uses configured application support directory")
    func sandboxRegistryURL() {
        HarnessHostPaths.$layoutOverride.withValue(HarnessHostLayout(
            applicationSupportDirectoryName: "TestHarness",
            swiftDataStoreFileName: "test.store"
        )) {
            let url = HarnessHostPaths.sandboxRegistryURL()
            #expect(url.path.contains("/TestHarness/sandbox-registry.json"))
            #expect(!url.path.contains("SwiftAhenHarness"))
        }
    }

    @Test("default swift data store uses configured file name")
    func defaultSwiftDataStoreURL() {
        HarnessHostPaths.$layoutOverride.withValue(HarnessHostLayout(
            applicationSupportDirectoryName: "TestHarness",
            swiftDataStoreFileName: "test.store"
        )) {
            let url = HarnessHostPaths.defaultSwiftDataStoreURL()
            #expect(url.lastPathComponent == "test.store")
            #expect(url.deletingLastPathComponent().lastPathComponent == "TestHarness")
        }
    }

    @Test("user settings path uses configured home directory name")
    func userSettingsURL() {
        HarnessHostPaths.$layoutOverride.withValue(HarnessHostLayout(
            applicationSupportDirectoryName: "TestHarness",
            swiftDataStoreFileName: "test.store",
            userSettingsDirectoryName: ".test-harness"
        )) {
            let url = HarnessHostPaths.userSettingsURL()
            #expect(url.path.contains("/.test-harness/settings.json"))
        }
    }
}
