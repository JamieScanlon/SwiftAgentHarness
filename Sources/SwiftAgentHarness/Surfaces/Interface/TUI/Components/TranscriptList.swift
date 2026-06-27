import Foundation

/// Virtualized transcript list: renders only the visible window plus margin.
public final class TranscriptListComponent: TUIComponent {
    public var messages: [TUIMessage]
    public var viewportRows: Int
    public var scrollOffset: Int
    public var marginRows: Int
    private var messageViews: [UUID: CachingComponent<MessageViewComponent>] = [:]
    private var lastWidth = 0
    private var pinnedToBottom = true

    public init(messages: [TUIMessage] = [], viewportRows: Int = 20, scrollOffset: Int = 0, marginRows: Int = 2) {
        self.messages = messages
        self.viewportRows = max(1, viewportRows)
        self.scrollOffset = scrollOffset
        self.marginRows = max(0, marginRows)
    }

    public func appendMessage(_ message: TUIMessage) {
        messages.append(message)
        _ = wrapper(for: message)
        scrollToBottom()
        invalidate()
    }

    public func activeStreamingView() -> MessageViewComponent? {
        guard let last = messages.last, last.isStreaming else { return nil }
        let cached = wrapper(for: last)
        cached.invalidate()
        return cached.inner
    }

    public func view(for message: TUIMessage) -> MessageViewComponent {
        wrapper(for: message).inner
    }

    public func scrollToBottom() {
        pinnedToBottom = true
        if lastWidth > 0 {
            scrollOffset = max(0, totalRenderedLines() - viewportRows)
        }
    }

    public func scrollBy(_ delta: Int) {
        pinnedToBottom = false
        let maxBottom = lastWidth > 0 ? max(0, totalRenderedLines() - viewportRows) : 0
        scrollOffset = max(0, min(maxBottom, scrollOffset + delta))
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    public func render(width: Int) -> [String] {
        lastWidth = width
        guard !messages.isEmpty else {
            return [ANSIStyle.finishLine(ANSIStyle.dim("(no messages yet)"))]
        }

        let heights = messages.map { wrapper(for: $0).render(width: width).count }
        let total = heights.reduce(0, +)
        let maxBottom = max(0, total - viewportRows)
        if pinnedToBottom {
            scrollOffset = maxBottom
        } else {
            scrollOffset = min(scrollOffset, maxBottom)
            if scrollOffset >= maxBottom {
                pinnedToBottom = true
            }
        }

        let visibleStart = scrollOffset
        let visibleEnd = min(total, visibleStart + viewportRows + marginRows)
        var output: [String] = []
        var cumulative = 0

        for (index, message) in messages.enumerated() {
            let height = heights[index]
            let messageStart = cumulative
            let messageEnd = cumulative + height

            if messageEnd <= visibleStart {
                cumulative = messageEnd
                continue
            }
            if messageStart >= visibleEnd {
                break
            }

            let lines = wrapper(for: message).render(width: width)
            let localStart = max(0, visibleStart - messageStart)
            let localEnd = min(height, visibleEnd - messageStart)
            if localStart < localEnd {
                output.append(contentsOf: lines[localStart..<localEnd])
            }
            cumulative = messageEnd
        }

        return output
    }

    private func wrapper(for message: TUIMessage) -> CachingComponent<MessageViewComponent> {
        if let existing = messageViews[message.id] {
            return existing
        }
        let created = CachingComponent(MessageViewComponent(message: message), context: "MessageView")
        messageViews[message.id] = created
        return created
    }

    private func totalRenderedLines() -> Int {
        guard lastWidth > 0 else { return messages.count }
        return messages.reduce(0) { partial, message in
            partial + wrapper(for: message).render(width: lastWidth).count
        }
    }
}
