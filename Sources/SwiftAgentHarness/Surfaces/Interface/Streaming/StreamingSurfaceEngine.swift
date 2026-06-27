import Foundation

/// Drives outbound streaming for one surface attachment, consuming ``ChatStreamingPartial`` events.
public actor StreamingSurfaceEngine {
    private let capabilities: StreamingSurfaceCapabilities
    private let sink: any StreamingSurfaceSink
    private var chunker: BlockChunker
    private var coalescer: BlockCoalescer
    private let pacer: HumanPacer
    private let pacedSender: PacedBlockSender
    private var previewStreamer: PreviewStreamer?
    private var mediaLedger = MediaDeliveryLedger()
    private var coalesceFlushTask: Task<Void, Never>?

    private var accumulatedText = ""
    private var messageEndBuffer = ""
    private var cancelled = false

    public init(capabilities: StreamingSurfaceCapabilities, sink: any StreamingSurfaceSink) {
        self.capabilities = capabilities
        self.sink = sink
        self.chunker = BlockChunker(
            config: capabilities.chunker,
            breakPreference: capabilities.breakPreference
        )
        self.coalescer = BlockCoalescer(
            config: capabilities.coalescing,
            maxChars: capabilities.chunker.effectiveMaxChars,
            breakPreference: capabilities.breakPreference
        )
        self.pacer = HumanPacer(config: capabilities.pacing)
        self.pacedSender = PacedBlockSender(pacer: pacer, sink: sink)

        if capabilities.usesPreviewStreaming {
            self.previewStreamer = PreviewStreamer(
                mode: capabilities.effectivePreviewMode,
                chunkerConfig: capabilities.chunker
            )
        }
    }

    /// Awaits the in-flight coalesce debounce timer (test hook).
    func awaitCoalesceFlush() async {
        await coalesceFlushTask?.value
        await pacedSender.drain()
    }

    /// Consumes one streaming partial from the conversation event stream.
    public func ingest(_ partial: ChatStreamingPartial) async {
        guard !cancelled else { return }

        switch partial {
        case .text(let text):
            accumulatedText += text
            await routeText(text)
        case .reasoning(let text, _):
            if capabilities.granularity == .tokenDelta {
                await sink.sendReasoningDelta(text)
            }
        case .toolCall(let toolName, _, _, _):
            await routeToolProgress(toolName: toolName)
        case .surfaceIntent:
            break
        }
    }

    /// Flushes intra-turn segment boundaries without finalizing the turn.
    public func flushSegment() async {
        guard !cancelled else { return }

        switch capabilities.granularity {
        case .tokenDelta:
            return
        case .block:
            guard capabilities.usesBlockStreaming else { return }
            await flushBlocksAtBoundary()
        case .previewEdit:
            guard capabilities.usesPreviewStreaming, var preview = previewStreamer else { return }
            for update in preview.flush() {
                await sink.upsertPreview(update)
            }
            previewStreamer = preview
        case .finalOnly:
            break
        }
    }

    /// Completes the turn with the final committed payload.
    public func finish(final: StreamingFinalPayload) async {
        guard !cancelled else { return }

        cancelCoalesceTimer()

        if capabilities.usesBlockStreaming {
            await flushBlocksAtBoundary()
            await pacedSender.drain()
        }

        if var preview = previewStreamer {
            for update in preview.flush() {
                await sink.upsertPreview(update)
            }
            await sink.resolvePreview(preview.resolveForFinal())
            previewStreamer = preview
        }

        if let prepared = mediaLedger.prepareFinal(final) {
            await sink.sendFinal(prepared)
        }

        await resetTurnState()
    }

    /// Cancels an in-flight turn per the configured granularity policy.
    public func cancel() async {
        cancelled = true
        let partial = accumulatedText

        cancelCoalesceTimer()
        chunker.discardPending()
        await coalescer.discardPending()
        messageEndBuffer = ""
        await pacedSender.reset()

        let actions = StreamingCancellation.resolve(
            granularity: capabilities.granularity,
            partialText: partial,
            cancellationMarker: capabilities.cancellationMarker
        )

        for action in actions {
            switch action {
            case .keepPartial:
                break
            case .appendCancellationMarker(let marker):
                await sink.sendBlock(marker)
            case .resolvePreview(let resolution):
                await sink.resolvePreview(resolution)
            case .emitNotice(let notice):
                await sink.emitCancellation(notice)
            }
        }

        await resetTurnState()
    }

    /// Convenience: consume an entire partial stream then finish.
    public func consume(
        stream: AsyncStream<ChatStreamingPartial>,
        final: StreamingFinalPayload
    ) async {
        for await partial in stream {
            await ingest(partial)
        }
        await finish(final: final)
    }

    // MARK: - Routing

    private func routeText(_ text: String) async {
        switch capabilities.granularity {
        case .tokenDelta:
            await sink.sendTokenDelta(text)
        case .block:
            await routeBlockText(text)
        case .previewEdit:
            await routePreviewText(text)
        case .finalOnly:
            break
        }
    }

    private func routeBlockText(_ text: String) async {
        guard capabilities.usesBlockStreaming else {
            return
        }

        if capabilities.blockStreaming.breakBoundary == .messageEnd {
            messageEndBuffer += text
            return
        }

        let chunks = chunker.ingest(text)
        for chunk in chunks {
            await emitBlock(chunk)
        }
    }

    private func routePreviewText(_ text: String) async {
        guard capabilities.usesPreviewStreaming, var preview = previewStreamer else { return }
        for update in preview.ingestText(text) {
            await sink.upsertPreview(update)
        }
        previewStreamer = preview
    }

    private func routeToolProgress(toolName: String?) async {
        let line = toolProgressLine(toolName: toolName)

        if capabilities.usesPreviewStreaming, var preview = previewStreamer {
            for update in preview.ingestToolProgress(line) {
                await sink.upsertPreview(update)
            }
            previewStreamer = preview
            return
        }

        if capabilities.surfacesToolProgressInBlockMode {
            await sink.upsertPreview(.toolProgress(line))
        }
    }

    private func flushBlocksAtBoundary() async {
        if capabilities.blockStreaming.breakBoundary == .messageEnd {
            await emitBlocks(from: messageEndBuffer)
            messageEndBuffer = ""
        } else {
            for chunk in chunker.flush() {
                await emitBlock(chunk)
            }
        }
        await drainCoalescerFinal()
    }

    private func drainCoalescerFinal() async {
        cancelCoalesceTimer()
        guard capabilities.coalescing.enabled else { return }
        for block in await coalescer.flushFinal() {
            await pacedSender.enqueue(block)
        }
    }

    private func emitBlocks(from text: String) async {
        guard !text.isEmpty else { return }
        var localChunker = BlockChunker(
            config: capabilities.chunker,
            breakPreference: capabilities.breakPreference
        )
        for chunk in localChunker.ingest(text) + localChunker.flush() {
            await emitBlock(chunk)
        }
    }

    private func emitBlock(_ chunk: String) async {
        guard !chunk.isEmpty else { return }

        let coalesced = await coalescer.ingest(chunk)
        for block in coalesced {
            await pacedSender.enqueue(block)
        }

        mediaLedger.recordBlock(chunk)
        armCoalesceTimer()
    }

    private func armCoalesceTimer() {
        guard capabilities.coalescing.enabled else { return }
        coalesceFlushTask?.cancel()
        let idleMs = capabilities.coalescing.idleMs
        coalesceFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(idleMs))
            if Task.isCancelled { return }
            await self?.drainDueCoalesced()
        }
    }

    private func drainDueCoalesced() async {
        guard !cancelled else { return }
        for block in await coalescer.flushDue() {
            await pacedSender.enqueue(block)
        }
    }

    private func cancelCoalesceTimer() {
        coalesceFlushTask?.cancel()
        coalesceFlushTask = nil
    }

    private func toolProgressLine(toolName: String?) -> String {
        guard let toolName, !toolName.isEmpty else {
            return "Working…"
        }
        switch toolName.lowercased() {
        case "web_search", "websearch", "search":
            return "Searching the web…"
        case "read", "read_file", "filesystem_read":
            return "Reading file…"
        default:
            return "Running \(toolName)…"
        }
    }

    private func resetTurnState() async {
        cancelCoalesceTimer()
        accumulatedText = ""
        messageEndBuffer = ""
        cancelled = false
        mediaLedger.reset()
        await pacedSender.reset()
        chunker = BlockChunker(
            config: capabilities.chunker,
            breakPreference: capabilities.breakPreference
        )
        coalescer = BlockCoalescer(
            config: capabilities.coalescing,
            maxChars: capabilities.chunker.effectiveMaxChars,
            breakPreference: capabilities.breakPreference
        )
        if capabilities.usesPreviewStreaming {
            previewStreamer = PreviewStreamer(
                mode: capabilities.effectivePreviewMode,
                chunkerConfig: capabilities.chunker
            )
        }
    }
}
