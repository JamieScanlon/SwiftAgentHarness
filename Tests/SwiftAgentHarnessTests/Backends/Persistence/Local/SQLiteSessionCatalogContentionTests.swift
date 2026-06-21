import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("SQLite session catalog contention")
struct SQLiteSessionCatalogContentionTests {
    @Test func secondConnectionCompletesAfterConcurrentTransaction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-contention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("catalog.sqlite")

        let blocker = try SQLiteSessionCatalog(fileURL: url)
        let waiter = try SQLiteSessionCatalog(fileURL: url)

        let group = DispatchGroup()
        group.enter()
        Thread {
            defer { group.leave() }
            try? blocker.exec("BEGIN IMMEDIATE;")
            Thread.sleep(forTimeInterval: 0.4)
            try? blocker.exec("COMMIT;")
        }.start()

        Thread.sleep(forTimeInterval: 0.05)

        let cid = UUID()
        let record = SessionCatalogRecord(
            id: cid,
            topic: "c",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try waiter.insertConversation(record)

        group.wait()
        let fetched = try waiter.fetchCatalogConversation(id: cid)
        #expect(fetched?.id == cid)
    }
}
