//
//  Process-wide depth of held v2 transcript write locks (Gap 11 strict mode). Updated by ``ProcessAwareTranscriptWriteLock``.
//

import Foundation

enum TranscriptWriteLockHeldRegistry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var depths: [UUID: Int] = [:]
    }

    private static let storage = Storage()

    static func incrementHeld(conversationID: UUID) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.depths[conversationID, default: 0] += 1
    }

    static func decrementHeld(conversationID: UUID) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard let current = storage.depths[conversationID] else { return }
        if current <= 1 {
            storage.depths.removeValue(forKey: conversationID)
        } else {
            storage.depths[conversationID] = current - 1
        }
    }

    static func isWriteLockHeld(conversationID: UUID) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return (storage.depths[conversationID] ?? 0) > 0
    }
}
