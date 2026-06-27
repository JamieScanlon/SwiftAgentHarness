import Foundation

/// Drives ``StreamingSurfaceEngine`` for one channel turn from conversation topic partials.
public actor ChannelStreamingRunConsumer: ConversationStreamConsumer {
    private let engine: StreamingSurfaceEngine
    private let verboseDetailSink: ChannelStreamingSurfaceSink?

    public init(
        capabilities: StreamingSurfaceCapabilities,
        mainSink: ChannelStreamingSurfaceSink,
        verboseDetailSink: ChannelStreamingSurfaceSink?
    ) {
        self.engine = StreamingSurfaceEngine(capabilities: capabilities, sink: mainSink)
        self.verboseDetailSink = verboseDetailSink
    }

    public func ingest(_ partial: ChatStreamingPartial) async {
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

    public func flushSegment() async {
        await engine.flushSegment()
    }

    public func finishTurn(final: StreamingFinalPayload) async {
        await engine.finish(final: final)
    }

    public func cancelTurn() async {
        await engine.cancel()
    }

    private static func verboseToolDetail(toolName: String, fragment: String) -> String? {
        guard !fragment.isEmpty else { return nil }
        return "`\(toolName)`: \(fragment)"
    }
}
