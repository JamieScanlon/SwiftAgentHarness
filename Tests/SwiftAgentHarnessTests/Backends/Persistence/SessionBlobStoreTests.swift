import Foundation
@testable import SwiftAgentHarness
import Testing

@Suite("Session blob store")
struct SessionBlobStoreTests {
    private func makeStore() throws -> (SessionBlobStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-blob-\(UUID().uuidString)", isDirectory: true)
        let store = SessionBlobStore(root: root, maxBytes: 1024 * 1024)
        return (store, root)
    }

    @Test func putIsContentAddressedAndIdempotent() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("hello blob".utf8)
        let first = try store.put(data: data, durability: .durable, originalName: "a.txt", mimeTypeHint: "text/plain", trust: "user-direct", ttlSeconds: nil)
        let second = try store.put(data: data, durability: .durable, originalName: "b.txt", mimeTypeHint: nil, trust: "user-direct", ttlSeconds: nil)
        #expect(first.id == second.id)
        #expect(first.id == SessionBlobStore.sha256Hex(data))
        let roundTrip = try store.get(blobId: first.id)
        #expect(roundTrip == data)
    }

    @Test func rejectsOversizeBlob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-blob-big-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionBlobStore(root: root, maxBytes: 8)
        let data = Data(repeating: 0xAB, count: 16)
        do {
            _ = try store.put(data: data, durability: .durable, originalName: nil, mimeTypeHint: nil, trust: "user-direct", ttlSeconds: nil)
            Issue.record("expected blobTooLarge")
        } catch SessionPersistenceError.blobTooLarge(let size, let maxBytes) {
            #expect(size == 16)
            #expect(maxBytes == 8)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func ephemeralBlobExpires() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let ref = try store.put(
            data: data,
            durability: .ephemeral,
            originalName: "x.png",
            mimeTypeHint: nil,
            trust: "unknown-party",
            ttlSeconds: 1,
            lane: .inbound,
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(ref.expiresAt != nil)
        _ = try store.get(blobId: ref.id, now: Date(timeIntervalSince1970: 100.5))
        do {
            _ = try store.get(blobId: ref.id, now: Date(timeIntervalSince1970: 102))
            Issue.record("expected blobExpired")
        } catch SessionPersistenceError.blobExpired {
            #expect(Bool(true))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func promoteMovesEphemeralToDurable() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("promote me".utf8)
        let ephemeral = try store.put(
            data: data,
            durability: .ephemeral,
            originalName: "shot.png",
            mimeTypeHint: "text/plain",
            trust: "unknown-party",
            ttlSeconds: 60,
            lane: .inbound
        )
        let promoted = try store.promote(blobId: ephemeral.id)
        #expect(promoted.durability == .durable)
        #expect(promoted.expiresAt == nil)
        #expect(try store.get(blobId: promoted.id) == data)
        let path = try #require(try store.blobPath(blobId: promoted.id))
        #expect(path.path.contains("/media/blobs/"))
    }

    @Test func sweepRemovesExpiredEphemeralOnly() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000)
        _ = try store.put(
            data: Data("old".utf8),
            durability: .ephemeral,
            originalName: nil,
            mimeTypeHint: nil,
            trust: "unknown-party",
            ttlSeconds: 10,
            lane: .outbound,
            now: now
        )
        let durable = try store.put(
            data: Data("keep".utf8),
            durability: .durable,
            originalName: nil,
            mimeTypeHint: nil,
            trust: "user-direct",
            ttlSeconds: nil,
            now: now
        )
        let swept = try store.sweepExpired(now: now.addingTimeInterval(20))
        #expect(swept == 1)
        #expect(try store.get(blobId: durable.id) == Data("keep".utf8))
    }

    @Test func markUnreferencedMovesOrphanToTrash() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1000)
        let orphan = try store.put(
            data: Data("orphan".utf8),
            durability: .durable,
            originalName: "o.txt",
            mimeTypeHint: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            now: now
        )
        let trashed = try store.markUnreferencedDurableForTrash(liveBlobIds: [], now: now)
        #expect(trashed == 1)
        let trashURL = SessionPersistenceLayout.durableTrashFileURL(root: root, blobId: orphan.id)
        #expect(FileManager.default.fileExists(atPath: trashURL.path))
        #expect(SessionBlobStore.durableFileExists(root: root, blobId: orphan.id))
        let prefix = String(orphan.id.prefix(2))
        let liveURL = SessionPersistenceLayout.durableBlobFileURL(root: root, hashPrefix: prefix, blobId: orphan.id)
        #expect(!FileManager.default.fileExists(atPath: liveURL.path))
    }

    @Test func getResurrectsTrashedBlobToLivePath() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("restore-me".utf8)
        let ref = try store.put(data: data, durability: .durable, originalName: "r.txt", mimeTypeHint: "text/plain", trust: "user-direct", ttlSeconds: nil)
        _ = try store.markUnreferencedDurableForTrash(liveBlobIds: [])
        #expect(try store.get(blobId: ref.id) == data)
        let prefix = String(ref.id.prefix(2))
        let liveURL = SessionPersistenceLayout.durableBlobFileURL(root: root, hashPrefix: prefix, blobId: ref.id)
        #expect(FileManager.default.fileExists(atPath: liveURL.path))
        #expect(!FileManager.default.fileExists(atPath: SessionPersistenceLayout.durableTrashFileURL(root: root, blobId: ref.id).path))
    }

    @Test func putSameBytesAfterMarkResurrectsWithoutDangling() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("re-paste".utf8)
        let ref = try store.put(
            data: data,
            durability: .durable,
            originalName: "a.txt",
            mimeTypeHint: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        _ = try store.markUnreferencedDurableForTrash(liveBlobIds: [], now: Date(timeIntervalSince1970: 100))
        _ = try store.put(data: data, durability: .durable, originalName: "b.txt", mimeTypeHint: nil, trust: "user-direct", ttlSeconds: nil)
        #expect(SessionBlobStore.durableFileExists(root: root, blobId: ref.id))
        let prefix = String(ref.id.prefix(2))
        let liveURL = SessionPersistenceLayout.durableBlobFileURL(root: root, hashPrefix: prefix, blobId: ref.id)
        #expect(FileManager.default.fileExists(atPath: liveURL.path))
        #expect(try store.get(blobId: ref.id) == data)
    }

    @Test func hardDeleteExpiredTrashRemovesAfterRetention() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let markTime = Date(timeIntervalSince1970: 1000)
        let orphan = try store.put(
            data: Data("gone".utf8),
            durability: .durable,
            originalName: "g.txt",
            mimeTypeHint: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            now: markTime
        )
        _ = try store.markUnreferencedDurableForTrash(liveBlobIds: [], now: markTime)
        let deletedEarly = try store.hardDeleteExpiredTrash(liveBlobIds: [], retentionInterval: 3600, now: markTime.addingTimeInterval(10))
        #expect(deletedEarly == 0)
        #expect(SessionBlobStore.durableFileExists(root: root, blobId: orphan.id))
        let deleted = try store.hardDeleteExpiredTrash(liveBlobIds: [], retentionInterval: 3600, now: markTime.addingTimeInterval(3600))
        #expect(deleted == 1)
        #expect(!SessionBlobStore.durableFileExists(root: root, blobId: orphan.id))
        #expect(throws: SessionPersistenceError.self) {
            try store.get(blobId: orphan.id)
        }
    }

    @Test func hardDeleteExpiredTrashSkipsReReferencedBlob() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let markTime = Date(timeIntervalSince1970: 2000)
        let blob = try store.put(
            data: Data("live-again".utf8),
            durability: .durable,
            originalName: "x.txt",
            mimeTypeHint: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            now: markTime
        )
        _ = try store.markUnreferencedDurableForTrash(liveBlobIds: [], now: markTime)
        let deleted = try store.hardDeleteExpiredTrash(
            liveBlobIds: [blob.id],
            retentionInterval: 0,
            now: markTime.addingTimeInterval(10)
        )
        #expect(deleted == 0)
        #expect(SessionBlobStore.durableFileExists(root: root, blobId: blob.id))
    }

    @Test func deleteBlobRemovesTrashEntry() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try store.put(data: Data("purge".utf8), durability: .durable, originalName: "p.txt", mimeTypeHint: "text/plain", trust: "user-direct", ttlSeconds: nil)
        _ = try store.markUnreferencedDurableForTrash(liveBlobIds: [])
        try store.delete(blobId: ref.id)
        #expect(!SessionBlobStore.durableFileExists(root: root, blobId: ref.id))
    }

    @Test func reclaimRunsMarkThenCollect() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let markTime = Date(timeIntervalSince1970: 5000)
        let orphan = try store.put(
            data: Data("reclaim".utf8),
            durability: .durable,
            originalName: "r.txt",
            mimeTypeHint: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            now: markTime
        )
        let counts = try store.reclaimUnreferencedDurable(liveBlobIds: [], trashRetentionInterval: 0, now: markTime)
        #expect(counts.trashed == 1)
        #expect(counts.hardDeleted == 1)
        #expect(!SessionBlobStore.durableFileExists(root: root, blobId: orphan.id))
    }
}
