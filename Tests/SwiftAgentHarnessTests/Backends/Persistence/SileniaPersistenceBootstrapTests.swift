import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessPersistenceBootstrap", .serialized)
struct PersistenceBootstrapTests {
    @Test("Quarantines corrupt store and opens fresh container")
    func quarantinesCorruptStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-bootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let storeURL = root.appendingPathComponent("SwiftAgentHrness.store")
        try Data("not-a-swiftdata-store".utf8).write(to: storeURL)

        let container = HarnessPersistenceBootstrap.makeModelContainer(
            dataStoreURL: storeURL,
            allowsSwiftDataSave: true,
            logger: nil
        )
        let context = ModelContext(container)
        let anchors = try context.fetch(FetchDescriptor<HarnessSchemaV22.CachedSchemaAnchor>())
        #expect(anchors.isEmpty)

        let recoveryDirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recovery-") }
        #expect(!recoveryDirs.isEmpty)
    }
}
