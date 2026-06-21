import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

#if canImport(Darwin)
import Darwin
#endif

@Suite("Harness session persistence Gap 10 (transcript lock parity)")
struct SessionPersistenceGap10Tests {
    @Test func acquireReturnsProcessAwareLockWithAcquiredAt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap10-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var row = SessionCatalogRecord(
            id: cid,
            topic: "t",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        row.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(row)

        let before = Date()
        let lock = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false, timeoutMs: 5_000)
        #expect(lock.acquiredAt >= before)
        #expect(lock.acquiredAt <= Date())
        #expect(type(of: lock) == ProcessAwareTranscriptWriteLock.self)
        lock.unlock()
    }

    #if canImport(Darwin)
    @Test func lockTimeoutWhenFlockContended() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap10-to-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var row = SessionCatalogRecord(
            id: cid,
            topic: "t",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        row.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(row)

        let lockURL = SessionPersistenceLayout.transcriptLockURL(root: root, agentId: SessionPersistenceLayout.defaultAgentId, conversationId: cid)
        let holderFd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(holderFd >= 0)
        let flockFn: @convention(c) (Int32, Int32) -> Int32 = flock
        #expect(flockFn(holderFd, LOCK_EX | LOCK_NB) == 0)

        var caught: SessionPersistenceError?
        do {
            _ = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false, timeoutMs: 150)
        } catch let e as SessionPersistenceError {
            caught = e
        }
        #expect(caught != nil)
        if case .lockTimeout = caught {} else {
            Issue.record("expected lockTimeout got \(String(describing: caught))")
        }

        _ = flockFn(holderFd, LOCK_UN)
        close(holderFd)
    }
    #endif

    @Test func reentrantSecondAcquireReturnsShimOnSameThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap10-re-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var row = SessionCatalogRecord(
            id: cid,
            topic: "t",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        row.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(row)

        let outer = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: true, timeoutMs: 5_000)
        let inner = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: true, timeoutMs: 5_000)
        #expect(inner.acquiredAt == outer.acquiredAt)
        #expect(type(of: outer) == ProcessAwareTranscriptWriteLock.self)
        inner.unlock()
        outer.unlock()
    }

    @Test func nonReentrantSecondAcquireThrowsOnSameThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap10-nore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var row = SessionCatalogRecord(
            id: cid,
            topic: "t",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        row.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(row)

        let outer = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false, timeoutMs: 5_000)
        defer { outer.unlock() }
        #expect(throws: SessionPersistenceError.self) {
            try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false, timeoutMs: 5_000)
        }
    }

    @Test func shutdownRegistryUnlockReleasesHeldTranscriptLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap10-shutdown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var row = SessionCatalogRecord(
            id: cid,
            topic: "t",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        row.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(row)

        let first = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false, timeoutMs: 5_000)
        TranscriptLockSignalRegistry.shared.unlockAllRegisteredLocks()

        let second = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false, timeoutMs: 250)
        second.unlock()
        first.unlock()
    }

    @Test func concurrentShutdownAndDeferUnlockIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap10-concurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var row = SessionCatalogRecord(
            id: cid,
            topic: "t",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        row.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(row)

        let holderReady = DispatchGroup()
        let holderDone = DispatchGroup()
        holderReady.enter()
        holderDone.enter()
        var holderError: Error?
        DispatchQueue.global().async {
            defer { holderDone.leave() }
            do {
                let held = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false, timeoutMs: 5_000)
                guard let processLock = held as? ProcessAwareTranscriptWriteLock else {
                    Issue.record("expected ProcessAwareTranscriptWriteLock")
                    return
                }
                holderReady.leave()
                let releaseGroup = DispatchGroup()
                for _ in 0 ..< 4 {
                    releaseGroup.enter()
                    DispatchQueue.global().async {
                        processLock.unlock()
                        TranscriptLockSignalRegistry.shared.unlockAllRegisteredLocks()
                        releaseGroup.leave()
                    }
                }
                releaseGroup.wait()
            } catch {
                holderError = error
                holderReady.leave()
            }
        }
        holderReady.wait()
        if let holderError {
            throw holderError
        }
        holderDone.wait()

        let second = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false, timeoutMs: 250)
        second.unlock()
    }
}
