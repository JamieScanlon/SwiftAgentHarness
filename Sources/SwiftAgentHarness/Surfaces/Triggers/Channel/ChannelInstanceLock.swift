import Foundation

enum ChannelInstanceLock {
    static func lockURL(dataDirectory: URL, channel: ChannelId, platformIdentity: String) -> URL {
        let dir = dataDirectory.appendingPathComponent("channel-locks", isDirectory: true)
        let safeIdentity = platformIdentity.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(channel.rawValue)-\(safeIdentity).lock")
    }

    static func tryAcquire(dataDirectory: URL, channel: ChannelId, platformIdentity: String) throws -> Bool {
        let url = lockURL(dataDirectory: dataDirectory, channel: channel, platformIdentity: platformIdentity)
        return try SchedulerLock.tryAcquire(lockURL: url, identity: "\(channel.rawValue):\(platformIdentity)")
    }

    static func release(dataDirectory: URL, channel: ChannelId, platformIdentity: String) throws {
        let url = lockURL(dataDirectory: dataDirectory, channel: channel, platformIdentity: platformIdentity)
        try SchedulerLock.release(lockURL: url, identity: "\(channel.rawValue):\(platformIdentity)")
    }

    static func readOwnerPID(dataDirectory: URL, channel: ChannelId, platformIdentity: String) throws -> Int32? {
        let url = lockURL(dataDirectory: dataDirectory, channel: channel, platformIdentity: platformIdentity)
        return try SchedulerLock.read(lockURL: url)?.ownerPID
    }
}
