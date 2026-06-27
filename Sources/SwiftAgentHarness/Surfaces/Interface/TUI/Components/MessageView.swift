import Foundation

public final class MessageViewComponent: TUIComponent {
    public var message: TUIMessage
    public var streamingTail: String

    public init(message: TUIMessage, streamingTail: String = "") {
        self.message = message
        self.streamingTail = streamingTail
    }

    public func appendToken(_ token: String) {
        streamingTail += token
        invalidate()
    }

    public func commitStreaming() {
        if !streamingTail.isEmpty {
            message.content += streamingTail
            streamingTail = ""
        }
        message.isStreaming = false
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    public func render(width: Int) -> [String] {
        let prefix: String
        switch message.role {
        case .user:
            prefix = ANSIStyle.bold(ANSIStyle.color("You", fg: 39))
        case .assistant:
            prefix = ANSIStyle.bold(ANSIStyle.color("Assistant", fg: 46))
        case .system:
            prefix = ANSIStyle.dim("System")
        case .tool:
            prefix = ANSIStyle.color("Tool", fg: 214)
        }
        let body = message.content + streamingTail + (message.isStreaming ? "▌" : "")
        let header = ANSITruncate.truncate(prefix, toWidth: width)
        var lines = [ANSIStyle.finishLine(header)]
        lines.append(contentsOf: ANSIWrap.wrap(body, width: width))
        return lines
    }
}
