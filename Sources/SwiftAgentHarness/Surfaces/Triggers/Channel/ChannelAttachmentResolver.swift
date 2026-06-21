import Foundation

enum ChannelAttachmentResolver {
    static func resolve(
        event: ChannelMessageEvent,
        mediaRoot: URL,
        channel: ChannelId
    ) -> ChannelMessageEvent {
        var resolved = event
        let channelDir = mediaRoot.appendingPathComponent(channel.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        resolved.attachments = event.attachments.map { attachment in
            guard attachment.localPath == nil else { return attachment }
            var copy = attachment
            copy.localPath = channelDir.appendingPathComponent(attachment.filename).path
            return copy
        }
        return resolved
    }
}
