import Foundation

struct ChannelRuntimeStatusSnapshot: Codable, Sendable, Equatable {
    var channel: String
    var platformIdentity: String
    var state: ChannelListenerState
    var fatalError: ChannelFatalError?
    var counters: ChannelIntakeCounters
    var inflightDebounce: Int
    var updatedAt: Date
}

enum ChannelRuntimeStatus {
    static func statusURL(dataDirectory: URL, channel: ChannelId) -> URL {
        dataDirectory
            .appendingPathComponent("channel-status", isDirectory: true)
            .appendingPathComponent("\(channel.rawValue).json")
    }

    static func write(_ snapshot: ChannelRuntimeStatusSnapshot, dataDirectory: URL) throws {
        let url = statusURL(dataDirectory: dataDirectory, channel: ChannelId(rawValue: snapshot.channel) ?? .slack)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    static func recordFatal(channel: ChannelId, error: ChannelFatalError, dataDirectory: URL) {
        let snapshot = ChannelRuntimeStatusSnapshot(
            channel: channel.rawValue,
            platformIdentity: "unknown",
            state: .fatal,
            fatalError: error,
            counters: ChannelIntakeCounters(),
            inflightDebounce: 0,
            updatedAt: Date()
        )
        try? write(snapshot, dataDirectory: dataDirectory)
    }
}
