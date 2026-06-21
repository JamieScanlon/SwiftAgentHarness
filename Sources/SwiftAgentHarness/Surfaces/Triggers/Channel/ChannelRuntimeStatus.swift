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
}
