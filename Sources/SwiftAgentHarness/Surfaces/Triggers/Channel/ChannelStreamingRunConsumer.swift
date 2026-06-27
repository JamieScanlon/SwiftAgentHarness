import Foundation

/// Drives ``StreamingSurfaceEngine`` for one channel turn from conversation topic partials.
actor ChannelStreamingRunConsumer: ConversationStreamConsumer {
    private let engine: StreamingSurfaceEngine
    private let verboseDetailSink: ChannelStreamingSurfaceSink?

    init(
        capabilities: StreamingSurfaceCapabilities,
        mainSink: ChannelStreamingSurfaceSink,
        verboseDetailSink: ChannelStreamingSurfaceSink?
    ) {
        self.engine = StreamingSurfaceEngine(capabilities: capabilities, sink: mainSink)
        self.verboseDetailSink = verboseDetailSink
    }

    func ingest(_ partial: ChatStreamingPartial) async {
        if case .toolCall(let toolName, _, let fragment, _) = partial,
           let toolName,
           toolName != MessageToolArgumentsParser.toolName,
           let verboseDetailSink,
           let fragment,
           let detail = Self.verboseToolDetail(toolName: toolName, fragment: fragment) {
            await verboseDetailSink.sendBlock(detail)
        }
        await engine.ingest(partial)
    }

    func flushSegment() async {
        await engine.flushSegment()
    }

    func finishTurn(final: StreamingFinalPayload) async {
        await engine.finish(final: final)
    }

    func cancelTurn() async {
        await engine.cancel()
    }

    private static func verboseToolDetail(toolName: String, fragment: String) -> String? {
        guard !fragment.isEmpty else { return nil }
        return "`\(toolName)`: \(fragment)"
    }
}

/// Wraps a channel stream consumer and detaches the run subscription when the turn ends.
actor ChannelRunStreamingSessionConsumer: ConversationStreamConsumer {
    private let inner: ChannelStreamingRunConsumer
    private let onTurnEnded: @Sendable () async -> Void

    init(inner: ChannelStreamingRunConsumer, onTurnEnded: @escaping @Sendable () async -> Void) {
        self.inner = inner
        self.onTurnEnded = onTurnEnded
    }

    func ingest(_ partial: ChatStreamingPartial) async {
        await inner.ingest(partial)
    }

    func flushSegment() async {
        await inner.flushSegment()
    }

    func finishTurn(final: StreamingFinalPayload) async {
        await inner.finishTurn(final: final)
        await onTurnEnded()
    }

    func cancelTurn() async {
        await inner.cancelTurn()
        await onTurnEnded()
    }
}
