import Foundation

/// Virtualized transcript list: renders only the visible window plus margin.
public final class TranscriptListComponent: TUIComponent {
    public var messages: [TUIMessage]
    public var viewportRows: Int
    public var scrollOffset: Int
    public var marginRows: Int
    private var messageViews: [UUID: MessageViewComponent] = [:]

    public init(messages: [TUIMessage] = [], viewportRows: Int = 20, scrollOffset: Int = 0, marginRows: Int = 2) {
        self.messages = messages
        self.viewportRows = max(1, viewportRows)
        self.scrollOffset = scrollOffset
        self.marginRows = max(0, marginRows)
    }

    public func appendMessage(_ message: TUIMessage) {
        messages.append(message)
        messageViews[message.id] = MessageViewComponent(message: message)
        scrollToBottom()
        invalidate()
    }

    public func activeStreamingView() -> MessageViewComponent? {
        guard let last = messages.last, last.isStreaming else { return nil }
        return view(for: last)
    }

    public func view(for message: TUIMessage) -> MessageViewComponent {
        if let existing = messageViews[message.id] { return existing }
        let created = MessageViewComponent(message: message)
        messageViews[message.id] = created
        return created
    }

    public func scrollToBottom() {
        scrollOffset = max(0, estimatedTotalLines() - viewportRows)
    }

    public func scrollBy(_ delta: Int) {
        scrollOffset = max(0, min(max(0, estimatedTotalLines() - viewportRows), scrollOffset + delta))
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    public func render(width: Int) -> [String] {
        let layouts = messages.map { message -> (id: UUID, lines: [String]) in
            let view = view(for: message)
            return (message.id, view.render(width: width))
        }
        let lineEntries = layouts.flatMap { entry in
            entry.lines.map { (entry.id, $0) }
        }
        guard !lineEntries.isEmpty else {
            return [ANSIStyle.finishLine(ANSIStyle.dim("(no messages yet)"))]
        }

        let totalLines = lineEntries.count
        let visibleStart = max(0, min(scrollOffset, max(0, totalLines - 1)))
        let visibleEnd = min(totalLines, visibleStart + viewportRows + marginRows)
        let slice = lineEntries[visibleStart..<visibleEnd]
        return slice.map(\.1)
    }

    private func estimatedTotalLines() -> Int {
        messages.reduce(0) { partial, message in
            partial + max(1, message.content.split(separator: "\n", omittingEmptySubsequences: false).count + 1)
        }
    }
}
