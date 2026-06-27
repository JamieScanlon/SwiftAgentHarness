import Foundation

struct ChannelSessionLifecycleBucket {
    var channel: ChannelId?
    var debounceTasks: [Task<Void, Never>] = []
    var burstKeys: Set<String> = []
    var typingKeepalive: ChannelTypingKeepalive?
    var streamingDriveTask: Task<Void, Never>?
}

public struct ChannelSessionDrainResult: Sendable {
    public var channel: ChannelId?
    public var burstKeys: Set<String>
}

public actor ChannelSessionLifecycleCoordinator {
    private var buckets: [UUID: ChannelSessionLifecycleBucket] = [:]
    private var burstKeyToConversationID: [String: UUID] = [:]
    private var pendingDebounce: [String: [Task<Void, Never>]] = [:]
    nonisolated(unsafe) private var onSessionDrained: (@Sendable (ChannelSessionDrainResult) async -> Void)?

    nonisolated func setSessionDrainHandler(_ handler: @escaping @Sendable (ChannelSessionDrainResult) async -> Void) {
        onSessionDrained = handler
    }

    func bindBurstKeys(conversationID: UUID, channel: ChannelId, burstKeys: Set<String>) {
        var bucket = buckets[conversationID] ?? ChannelSessionLifecycleBucket()
        bucket.channel = channel
        bucket.burstKeys.formUnion(burstKeys)
        for key in burstKeys {
            burstKeyToConversationID[key] = conversationID
            if let pending = pendingDebounce.removeValue(forKey: key) {
                bucket.debounceTasks.append(contentsOf: pending)
            }
        }
        buckets[conversationID] = bucket
    }

    func registerDebounce(burstKey: String, task: Task<Void, Never>) {
        if let conversationID = burstKeyToConversationID[burstKey] {
            buckets[conversationID, default: ChannelSessionLifecycleBucket()].debounceTasks.append(task)
            buckets[conversationID]?.burstKeys.insert(burstKey)
        } else {
            pendingDebounce[burstKey, default: []].append(task)
        }
    }

    func registerStreaming(
        conversationID: UUID,
        channel: ChannelId,
        driveTask: Task<Void, Never>,
        typingKeepalive: ChannelTypingKeepalive?
    ) {
        var bucket = buckets[conversationID] ?? ChannelSessionLifecycleBucket()
        bucket.channel = channel
        bucket.streamingDriveTask = driveTask
        bucket.typingKeepalive = typingKeepalive
        buckets[conversationID] = bucket
    }

    func drainSession(conversationID: UUID) async -> ChannelSessionDrainResult {
        guard let bucket = buckets.removeValue(forKey: conversationID) else {
            return ChannelSessionDrainResult(channel: nil, burstKeys: [])
        }
        for key in bucket.burstKeys {
            burstKeyToConversationID.removeValue(forKey: key)
        }
        await bucket.typingKeepalive?.stop()
        var tasks = bucket.debounceTasks
        if let driveTask = bucket.streamingDriveTask {
            tasks.append(driveTask)
        }
        await ChannelLifecycleDrain.drain(tasks: tasks)
        let result = ChannelSessionDrainResult(channel: bucket.channel, burstKeys: bucket.burstKeys)
        if let onSessionDrained {
            await onSessionDrained(result)
        }
        return result
    }
}

enum ChannelDebounceBurstKey {
    static func make(chatId: String, threadId: String?) -> String {
        if let threadId, !threadId.isEmpty {
            return "\(chatId):\(threadId)"
        }
        return chatId
    }

    static func fromTriggerMetadata(_ metadata: [String: String]) -> Set<String> {
        guard let chatId = metadata["chatId"], !chatId.isEmpty else { return [] }
        return [make(chatId: chatId, threadId: metadata["threadId"])]
    }
}
