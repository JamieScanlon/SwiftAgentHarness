import Foundation

/// Virtualized transcript list: renders only the visible window plus margin.
public final class TranscriptListComponent: TUIComponent {
    public var messages: [TUIMessage] {
        didSet { pruneCaches() }
    }
    public var viewportRows: Int
    public var scrollOffset: Int
    public var marginRows: Int
    /// Upper bound on retained per-message render caches. Views beyond this are dropped
    /// and rebuilt on demand; without a bound the cache grows for the whole session.
    public var maximumCachedViews: Int

    private var messageViews: [UUID: CachingComponent<MessageViewComponent>] = [:]
    /// Cached line counts keyed by message, valid for `cachedHeightWidth`.
    private var messageHeights: [UUID: Int] = [:]
    private var cachedHeightWidth = 0
    private var lastWidth = 0
    private var pinnedToBottom = true

    public init(
        messages: [TUIMessage] = [],
        viewportRows: Int = 20,
        scrollOffset: Int = 0,
        marginRows: Int = 2,
        maximumCachedViews: Int = 500
    ) {
        self.messages = messages
        self.viewportRows = max(1, viewportRows)
        self.scrollOffset = scrollOffset
        self.marginRows = max(0, marginRows)
        self.maximumCachedViews = max(1, maximumCachedViews)
    }

    public func appendMessage(_ message: TUIMessage) {
        messages.append(message)
        _ = wrapper(for: message)
        messageHeights.removeValue(forKey: message.id)
        scrollToBottom()
        invalidate()
    }

    public func activeStreamingView() -> MessageViewComponent? {
        guard let last = messages.last, last.isStreaming else { return nil }
        let cached = wrapper(for: last)
        cached.invalidate()
        messageHeights.removeValue(forKey: last.id)
        return cached.inner
    }

    public func view(for message: TUIMessage) -> MessageViewComponent {
        wrapper(for: message).inner
    }

    /// Writes a mutated view's message back into `messages`, keeping the array and the
    /// cached view's value copy in sync. Divergence here strands `activeStreamingView()`
    /// on a finished message, so the next turn's tokens append to the previous reply.
    public func syncMessage(from view: MessageViewComponent) {
        guard let index = messages.firstIndex(where: { $0.id == view.message.id }) else { return }
        messages[index] = view.message
        messageHeights.removeValue(forKey: view.message.id)
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
        guard width > 0 else { return [] }
        lastWidth = width
        guard !messages.isEmpty else {
            return [ANSIStyle.finishLine(ANSIStyle.dim("(no messages yet)"))]
        }

        let heights = messages.map { height(of: $0, width: width) }
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
            let localEnd = min(min(height, lines.count), visibleEnd - messageStart)
            if localStart < localEnd {
                output.append(contentsOf: lines[localStart..<localEnd])
            }
            cumulative = messageEnd
        }

        return output
    }

    /// Line count for one message, cached per width.
    ///
    /// The height table used to be built by calling `render` on *every* message in the
    /// session on every frame — O(transcript) per keystroke and per streamed token,
    /// which is precisely what virtualization is supposed to avoid.
    private func height(of message: TUIMessage, width: Int) -> Int {
        if cachedHeightWidth != width {
            messageHeights.removeAll(keepingCapacity: true)
            cachedHeightWidth = width
        }
        if let cached = messageHeights[message.id] { return cached }
        let computed = wrapper(for: message).render(width: width).count
        messageHeights[message.id] = computed
        return computed
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
        return messages.reduce(0) { $0 + height(of: $1, width: lastWidth) }
    }

    /// Bounds the *view* cache only.
    ///
    /// Heights are kept for every message on purpose: the height table spans the whole
    /// transcript, so evicting a height forces the message to be re-rendered on the next
    /// frame — which would reintroduce the O(transcript)-per-frame cost this cache exists
    /// to remove. A height is one `Int`; a rendered view is an array of styled strings.
    private func pruneCaches() {
        guard messageViews.count > maximumCachedViews else { return }
        let retained = Set(messages.suffix(maximumCachedViews).map(\.id))
        messageViews = messageViews.filter { retained.contains($0.key) }
    }
}
