import Foundation

enum TriggerTimestampFormatting {
    private static let lock = NSLock()
    // ISO8601DateFormatter is not Sendable; all access is serialized by lock in isoString(from:).
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func isoString(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
