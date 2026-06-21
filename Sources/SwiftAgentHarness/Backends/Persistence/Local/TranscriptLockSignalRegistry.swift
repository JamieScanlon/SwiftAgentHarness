//
//  README: release all held transcript file locks on graceful shutdown (SIGINT/SIGTERM / etc.).
//  Callers register locks while held; ``unlockAllRegisteredLocks()`` runs on the main dispatch path (not a raw async-signal handler).
//

import Foundation

/// Holds weak refs to in-process ``ProcessAwareTranscriptWriteLock`` instances that currently hold `flock`.
/// Use of @unchecked Sendable is valid here
final class TranscriptLockSignalRegistry: @unchecked Sendable {
    static let shared = TranscriptLockSignalRegistry()

    private let mutex = NSLock()
    private var boxes: [WeakTranscriptLockBox] = []

    private init() {}

    func register(_ lock: ProcessAwareTranscriptWriteLock) {
        mutex.lock()
        boxes.append(WeakTranscriptLockBox(lock))
        boxes.removeAll { $0.lock == nil }
        mutex.unlock()
    }

    func unregister(_ lock: ProcessAwareTranscriptWriteLock) {
        mutex.lock()
        boxes.removeAll { $0.lock == nil || $0.lock === lock }
        mutex.unlock()
    }

    /// Invoke from CLI / server shutdown (e.g. SIGINT handler on main queue) before tearing down the process.
    func unlockAllRegisteredLocks() {
        mutex.lock()
        let snapshot = boxes
        boxes.removeAll()
        mutex.unlock()
        for box in snapshot {
            box.lock?.unlockFromShutdownPath()
        }
    }
}

private final class WeakTranscriptLockBox {
    weak var lock: ProcessAwareTranscriptWriteLock?
    init(_ lock: ProcessAwareTranscriptWriteLock) {
        self.lock = lock
    }
}
