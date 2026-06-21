import Foundation

struct ChannelDebounceBurst: Sendable, Equatable {
    var events: [ChannelMessageEvent]
    var mentionResults: [ChannelMentionGateResult]
}

actor ChannelInboundDebounce {
    private var pending: [String: ChannelDebounceBurst] = [:]
    private let debounceMs: Int
    private let maxFlushMs: Int

    init(debounceMs: Int) {
        self.debounceMs = debounceMs
        self.maxFlushMs = min(debounceMs * 3, 10_000)
    }

    func shouldDebounce(event: ChannelMessageEvent) -> Bool {
        event.type == .text
    }

    func append(event: ChannelMessageEvent, mentionResult: ChannelMentionGateResult) -> (key: String, waitMs: Int) {
        let key = burstKey(for: event)
        var burst = pending[key] ?? ChannelDebounceBurst(events: [], mentionResults: [])
        burst.events.append(event)
        burst.mentionResults.append(mentionResult)
        pending[key] = burst
        let firstAt = burst.events.first?.receivedAt ?? event.receivedAt
        let elapsed = Int(event.receivedAt - firstAt)
        let waitMs = elapsed >= maxFlushMs ? 0 : debounceMs
        return (key, waitMs)
    }

    func takeBurst(key: String) -> ChannelDebounceBurst? {
        pending.removeValue(forKey: key)
    }

    func inflightCount() -> Int {
        pending.values.reduce(0) { $0 + $1.events.count }
    }

    func cancelAll() {
        pending.removeAll()
    }

    private func burstKey(for event: ChannelMessageEvent) -> String {
        if let threadId = event.threadId {
            return "\(event.chatId):\(threadId)"
        }
        return event.chatId
    }
}
