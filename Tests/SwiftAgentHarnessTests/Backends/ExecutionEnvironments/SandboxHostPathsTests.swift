import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Sandbox host paths")
struct SandboxHostPathsTests {
    @Test("local exec temp lives under application support not /tmp")
    func localExecTempUnderAppSupport() {
        HarnessHostPaths.$layoutOverride.withValue(HarnessHostLayout(
            applicationSupportDirectoryName: "TestHarness",
            swiftDataStoreFileName: "test.store"
        )) {
            let url = SandboxHostPaths.localExecTempDirectory(scopeKey: "agent-a")
            let appSupport = HarnessHostPaths.applicationSupportDirectory().path
            #expect(url.path.hasPrefix(appSupport))
            #expect(url.path.contains("sandbox-tmp/local-agent-a"))
            #expect(!url.path.hasPrefix("/tmp"))
        }
    }

    @Test("openshell mirror lives under application support not /tmp")
    func openshellMirrorUnderAppSupport() {
        HarnessHostPaths.$layoutOverride.withValue(HarnessHostLayout(
            applicationSupportDirectoryName: "TestHarness",
            swiftDataStoreFileName: "test.store"
        )) {
            let url = SandboxHostPaths.openshellMirrorRoot(scopeKey: "scope-1")
            let appSupport = HarnessHostPaths.applicationSupportDirectory().path
            #expect(url.path.hasPrefix(appSupport))
            #expect(url.path.contains("openshell-mirrors/scope-1"))
            #expect(!url.path.contains("/tmp/sah-openshell-"))
        }
    }

    @Test("ensureDirectory creates mode 0700 directory")
    func ensureDirectoryCreates0700() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-host-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("nested", isDirectory: true)
        try SandboxHostPaths.ensureDirectory(at: target)
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(perms == 0o700)
    }
}
