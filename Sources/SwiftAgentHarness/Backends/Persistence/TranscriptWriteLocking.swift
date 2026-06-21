//
//  Write lock abstraction: in-process for in-memory backend; file-based for ``LocalHarnessSessionPersistence``.
//

import Foundation

/// Exclusive transcript mutation guard for one conversation (harness `acquire_write_lock`).
protocol TranscriptWriteLock: AnyObject {
    var conversationID: UUID { get }
    /// Time the lock was acquired (harness `WriteLock.acquired_at`).
    var acquiredAt: Date { get }
    func unlock()
}

/// Use of @unchecked Sendable is valid here
final class InProcessTranscriptWriteLock: TranscriptWriteLock, @unchecked Sendable {
    let conversationID: UUID
    private(set) var acquiredAt: Date = Date()
    private let nsLock = NSLock()
    private var locked = false

    init(conversationID: UUID) {
        self.conversationID = conversationID
    }

    func acquire() {
        nsLock.lock()
        locked = true
        acquiredAt = Date()
    }

    func unlock() {
        if locked {
            locked = false
            nsLock.unlock()
        }
    }

    deinit {
        unlock()
    }
}

/// Routes `acquireTranscriptWriteLock` to per-conversation locks (not re-entrant by default).
/// Use of @unchecked Sendable is valid here
final class InProcessTranscriptWriteLockRegistry: @unchecked Sendable {
    private let mapLock = NSLock()
    private var locks: [UUID: InProcessTranscriptWriteLock] = [:]

    func acquire(conversationID: UUID) -> InProcessTranscriptWriteLock {
        mapLock.lock()
        defer { mapLock.unlock() }
        if let existing = locks[conversationID] {
            return existing
        }
        let created = InProcessTranscriptWriteLock(conversationID: conversationID)
        locks[conversationID] = created
        return created
    }
}
