import Foundation
import Logging

actor ChannelIntakePipeline {
    private let config: ChannelListenerConfig
    private let channel: ChannelId
    private let mediaRoot: URL
    private let dedup: ChannelMessageDedup
    private let mentionGate: ChannelMentionGate
    private let debounce: ChannelInboundDebounce
    private let logger: Logger
    private(set) var counters = ChannelIntakeCounters()
    private let emitTrigger: @Sendable (HarnessTrigger) async -> Void
    private var debounceTasks: [String: Task<Void, Never>] = [:]

    init(
        channel: ChannelId,
        config: ChannelListenerConfig,
        mediaRoot: URL,
        logger: Logger,
        emitTrigger: @escaping @Sendable (HarnessTrigger) async -> Void
    ) {
        self.channel = channel
        self.config = config
        self.mediaRoot = mediaRoot
        self.logger = logger
        self.emitTrigger = emitTrigger
        self.dedup = ChannelMessageDedup()
        self.mentionGate = ChannelMentionGate(config: config.mention)
        self.debounce = ChannelInboundDebounce(debounceMs: config.debounce.textMs)
    }

    func process(event: ChannelMessageEvent) async {
        counters.parsed += 1
        if await dedup.isDuplicate(channel: channel, platformMessageId: event.platformMessageId) {
            counters.dedupDropped += 1
            logger.debug("channel_intake_dedup channel=\(channel.rawValue) id=\(event.platformMessageId)")
            return
        }
        let resolved = ChannelAttachmentResolver.resolve(event: event, mediaRoot: mediaRoot, channel: channel)
        if !ChannelAllowlistPolicy.isAllowed(event: resolved, config: config) {
            counters.authDenied += 1
            logger.debug("channel_intake_auth_denied channel=\(channel.rawValue) sender=\(event.senderId)")
            return
        }
        let mention = await mentionGate.evaluate(event: resolved)
        if mention.shouldSkip {
            counters.mentionSkipped += 1
            logger.debug("channel_intake_mention_skip channel=\(channel.rawValue) chat=\(event.chatId)")
            return
        }
        if await debounce.shouldDebounce(event: resolved) {
            let schedule = await debounce.append(event: resolved, mentionResult: mention)
            counters.debounceHeld += 1
            debounceTasks[schedule.key]?.cancel()
            let waitMs = schedule.waitMs
            let key = schedule.key
            debounceTasks[key] = Task {
                if waitMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
                }
                guard !Task.isCancelled else { return }
                await self.flushDebounce(key: key)
            }
            return
        }
        await emitBuilt(event: resolved, mention: mention, burst: nil)
    }

    func inflightDebounceCount() async -> Int {
        await debounce.inflightCount()
    }

    func stop() async {
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        await debounce.cancelAll()
    }

    private func flushDebounce(key: String) async {
        debounceTasks[key] = nil
        guard let burst = await debounce.takeBurst(key: key) else { return }
        await flushBurst(events: burst.events, mentionResults: burst.mentionResults)
    }

    private func flushBurst(events: [ChannelMessageEvent], mentionResults: [ChannelMentionGateResult]) async {
        guard let last = events.last, let mention = mentionResults.last else { return }
        let anyMentioned = mentionResults.contains { $0.effectiveWasMentioned }
        var merged = last
        merged.text = events.map(\.text).joined(separator: "\n")
        merged.platformMessageId = last.platformMessageId
        let burst = ChannelDebounceBurstMetadata(
            messageIds: events.map(\.platformMessageId),
            firstAt: events.first?.receivedAt ?? last.receivedAt,
            lastAt: last.receivedAt
        )
        var effectiveMention = mention
        if anyMentioned {
            effectiveMention = ChannelMentionGateResult(
                effectiveWasMentioned: true,
                shouldSkip: false,
                shouldBypassMention: mention.shouldBypassMention
            )
        }
        await emitBuilt(event: merged, mention: effectiveMention, burst: burst)
    }

    private func emitBuilt(
        event: ChannelMessageEvent,
        mention: ChannelMentionGateResult,
        burst: ChannelDebounceBurstMetadata?
    ) async {
        let trust = ChannelTrustClassifier.classify(
            event: event,
            config: config,
            effectiveWasMentioned: mention.effectiveWasMentioned
        )
        guard let trigger = try? ChannelTriggerBuilder.build(
            event: event,
            config: config,
            trust: trust,
            effectiveWasMentioned: mention.effectiveWasMentioned,
            burst: burst
        ) else { return }
        counters.emitted += 1
        await emitTrigger(trigger)
    }
}
