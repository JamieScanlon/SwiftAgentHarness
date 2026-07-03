import Foundation
import SwiftData
@testable import SwiftAgentHarness

/// Serializes SwiftData in-memory container bootstrapping across parallel tests.
enum HarnessTestModelContainer {
    private static let initLock = NSLock()

    static func makeInMemory() throws -> ModelContainer {
        initLock.lock()
        defer { initLock.unlock() }
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }
}
