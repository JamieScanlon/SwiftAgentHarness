import Foundation
@testable import SwiftAgentHarness
import Testing

@Suite("Session blob expiry")
struct SessionBlobExpiryTests {
    private func makeStore() -> (SessionBlobStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-blob-expiry-\(UUID().uuidString)", isDirectory: true)
        return (SessionBlobStore(root: root, maxBytes: 1024 * 1024), root)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let data = Data("screenshot bytes".utf8)

    @Test("Setting an ephemeral blob's expiry moves it, nil holds it, and a past expiry makes it sweepable")
    func ephemeral() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try store.put(data: data, durability: .ephemeral, ttlSeconds: 60, lane: .outbound, now: now)

        let held = try store.setExpiry(blobId: ref.id, expiresAt: nil, now: now)
        #expect(held.expiresAt == nil)
        #expect(try store.get(blobId: ref.id, now: now.addingTimeInterval(86_400 * 365)) == data)
        #expect(try store.sweepExpired(now: now.addingTimeInterval(86_400 * 365)) == 0)

        _ = try store.setExpiry(blobId: ref.id, expiresAt: now.addingTimeInterval(10), now: now)
        #expect(throws: SessionPersistenceError.self) { try store.get(blobId: ref.id, now: now.addingTimeInterval(11)) }
        #expect(try store.sweepExpired(now: now.addingTimeInterval(11)) == 1)
    }

    @Test("A durable blob is left alone: another owner may hold the same bytes")
    func durableUntouched() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = try store.put(data: data, durability: .durable, now: now)
        _ = try store.put(data: data, durability: .ephemeral, ttlSeconds: 60, lane: .outbound, now: now)

        let ref = try store.setExpiry(blobId: durable.id, expiresAt: now.addingTimeInterval(1), now: now)
        #expect(ref.durability == .durable)
        #expect(ref.expiresAt == nil)
        #expect(try store.get(blobId: durable.id, now: now.addingTimeInterval(3_600)) == data)
    }

    @Test("Putting the same ephemeral bytes again extends the expiry and never shortens it")
    func reputExtends() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.put(data: data, durability: .ephemeral, ttlSeconds: 60, lane: .outbound, now: now)
        let longer = try store.put(data: data, durability: .ephemeral, ttlSeconds: 600, lane: .outbound, now: now)
        #expect(longer.expiresAt == now.addingTimeInterval(600))
        let shorter = try store.put(data: data, durability: .ephemeral, ttlSeconds: 10, lane: .outbound, now: now)
        #expect(shorter.expiresAt == now.addingTimeInterval(600))
        #expect(try store.stat(blobId: first.id, now: now).expiresAt == now.addingTimeInterval(600))
    }

    @Test("The in-memory store follows the same rules, and a durable put upgrades an ephemeral blob")
    func inMemory() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let ephemeral = try harness.putBlob(data: data, durability: .ephemeral, originalName: nil, mimeType: nil, trust: "unknown-party", ttlSeconds: 60, lane: .outbound)
        let extended = try harness.putBlob(data: data, durability: .ephemeral, originalName: nil, mimeType: nil, trust: "unknown-party", ttlSeconds: 6_000, lane: .outbound)
        #expect((extended.expiresAt ?? .distantPast) > (ephemeral.expiresAt ?? .distantFuture))

        let held = try harness.setBlobExpiry(blobId: ephemeral.id, expiresAt: nil)
        #expect(held.expiresAt == nil && held.durability == .ephemeral)
        _ = try harness.setBlobExpiry(blobId: ephemeral.id, expiresAt: Date().addingTimeInterval(-1))
        #expect(throws: SessionPersistenceError.self) { try harness.getBlob(blobId: ephemeral.id) }

        let durable = try harness.putBlob(data: data, durability: .durable, originalName: nil, mimeType: nil, trust: "user-direct", ttlSeconds: nil, lane: .inbound)
        #expect(durable.durability == .durable && durable.expiresAt == nil)
        #expect(try harness.getBlob(blobId: durable.id) == data)
        #expect(try harness.setBlobExpiry(blobId: durable.id, expiresAt: Date()).durability == .durable)
        #expect(try harness.getBlob(blobId: durable.id) == data)
    }
}
