import Foundation

enum FileEventQueueWriter {
    static func writeImmediate(
        eventsDirectory: URL,
        basename: String,
        text: String,
        channelId: String? = nil,
        trust: FileEventTrustSidecar,
        recordWritePhase: (@Sendable (String) -> Void)? = nil
    ) throws {
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        let jsonURL = eventsDirectory.appendingPathComponent("\(basename).json")
        let payload = FileEventPayload(type: .immediate, text: text, channelId: channelId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let trustURL = FileEventQueueLayout.trustSidecarURL(for: jsonURL)
        recordWritePhase?("trust")
        try encoder.encode(trust).write(to: trustURL, options: .atomic)
        recordWritePhase?("json")
        try encoder.encode(payload).write(to: jsonURL, options: .atomic)
    }
}
