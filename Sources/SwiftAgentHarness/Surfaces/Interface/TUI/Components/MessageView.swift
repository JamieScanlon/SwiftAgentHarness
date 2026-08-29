import Foundation

public final class MessageViewComponent: TUIComponent {
    public var message: TUIMessage
    public var streamingTail: String
    public private(set) var renderCount = 0

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
        renderCount += 1
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
        let header = ANSITruncate.truncate(prefix, toWidth: width)
        var lines = [ANSIStyle.finishLine(header)]

        // Native rendering when the message arrived as a portable presentation; the text
        // floor in `content` is the fallback, not the default.
        if let presentation = message.presentation, streamingTail.isEmpty, !message.isStreaming {
            lines.append(contentsOf: MessagePresentationTerminalRenderer.render(presentation, width: width))
            return lines
        }

        let body = message.content + streamingTail + (message.isStreaming ? "▌" : "")
        lines.append(contentsOf: ANSIWrap.wrap(body, width: width))
        return lines
    }
}
