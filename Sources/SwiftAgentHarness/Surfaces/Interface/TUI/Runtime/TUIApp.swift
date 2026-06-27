import Foundation

/// Event loop driving the TUI surface from runtime streams.
public actor TUIApp {
    public let terminal: any Terminal
    public let renderer: DifferentialRenderer
    public var transcript: TranscriptListComponent
    public var composer: InputComposerComponent
    public var statusLine: StatusLineComponent
    public var toolPane: ToolPaneViewComponent
    public var reasoningView: ReasoningViewComponent
    public var overlayHost: OverlayHostComponent
    public var splitView: SplitComponent
    public var controlInputBridge: TUIControlInputBridge
    public var streamingSink: TUIStreamingSurfaceSink!
    public var streamingEngine: StreamingSurfaceEngine!

    private var running = false
    private var streamingConfigured = false
    private nonisolated let pasteInput = BracketedPasteAccumulatorBox()

    public init(terminal: any Terminal, registry: SlashCommandRegistry = .builtins(compactEnabled: true)) {
        self.terminal = terminal
        self.renderer = DifferentialRenderer(terminal: terminal)
        self.transcript = TranscriptListComponent(viewportRows: max(1, terminal.rows - 6))
        self.composer = InputComposerComponent()
        self.statusLine = StatusLineComponent()
        self.toolPane = ToolPaneViewComponent()
        self.reasoningView = ReasoningViewComponent()
        self.controlInputBridge = TUIControlInputBridge(registry: registry)

        let chatStack = StackComponent(children: [transcript, reasoningView])
        self.splitView = SplitComponent(primary: chatStack, secondary: toolPane)
        self.overlayHost = OverlayHostComponent(base: StackComponent(children: [splitView, statusLine, composer]))
    }

    private func configureStreamingIfNeeded() {
        guard !streamingConfigured else { return }
        streamingConfigured = true
        streamingSink = TUIStreamingSurfaceSink { [self] mutation in
            await self.applyStreamingMutation(mutation)
        }
        streamingEngine = StreamingSurfaceEngine(capabilities: .terminal, sink: streamingSink)
    }

    private func applyStreamingMutation(_ mutation: TUIStreamingSurfaceSink.TranscriptMutation) {
        switch mutation {
        case .tokenDelta(let text):
            TUIStreamingSurfaceSinkLogic.sendTokenDelta(text, to: transcript)
        case .final(let payload):
            TUIStreamingSurfaceSinkLogic.sendFinal(payload, to: transcript)
        case .cancellation(let notice):
            TUIStreamingSurfaceSinkLogic.emitCancellation(notice, to: transcript)
        case .previewCommit:
            transcript.activeStreamingView()?.commitStreaming()
            transcript.invalidate()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        terminal.start(onInput: { [weak self] data in
            guard let self else { return }
            let chunks = self.pasteInput.feed(data)
            guard !chunks.isEmpty else { return }
            Task { for chunk in chunks { await self.handleInput(chunk) } }
        }, onResize: { [weak self] columns, rows in
            Task { await self?.handleResize(columns: columns, rows: rows) }
        })
        Task { renderFrame(full: true) }
    }

    public func stop() {
        running = false
        terminal.stop()
    }

    public func ingest(_ partial: ChatStreamingPartial) async {
        configureStreamingIfNeeded()
        await streamingEngine.ingest(partial)
        switch partial {
        case .reasoning(let text, _):
            reasoningView.append(text)
        case .toolCall(let toolName, _, let fragment, _):
            toolPane.updateToolCall(name: toolName, fragment: fragment)
        case .surfaceIntent(let intent):
            await handleSurfaceIntent(intent)
        default:
            break
        }
        renderFrame()
    }

    public func finishTurn(final: StreamingFinalPayload) async {
        configureStreamingIfNeeded()
        await streamingEngine.finish(final: final)
        statusLine.showSpinner = false
        statusLine.phase = "idle"
        renderFrame()
    }

    public func cancelTurn() async {
        configureStreamingIfNeeded()
        await streamingEngine.cancel()
        statusLine.showSpinner = false
        statusLine.phase = "cancelled"
        renderFrame()
    }

    public func flushSegment() async {
        configureStreamingIfNeeded()
        await streamingEngine.flushSegment()
        renderFrame()
    }

    public func consume(
        partials: AsyncStream<ChatStreamingPartial>,
        orchestration: AsyncStream<ConversationOrchestrationState>,
        final: StreamingFinalPayload
    ) async {
        async let partialLoop: Void = {
            for await partial in partials {
                await self.ingest(partial)
            }
        }()
        async let orchestrationLoop: Void = {
            for await state in orchestration {
                await self.updateOrchestration(state)
            }
        }()
        _ = await (partialLoop, orchestrationLoop)
        await finishTurn(final: final)
    }

    public func submitComposer() -> ComposerSubmission {
        let submission = composer.makeSubmission()
        transcript.appendMessage(TUIMessage(role: .user, content: submission.text))
        composer.clear()
        return submission
    }

    public func classifySubmission(_ submission: ComposerSubmission) -> ControlInputClassification {
        controlInputBridge.classify(submission)
    }

    public func showApproval(_ presentation: ApprovalPresentation, approvalID: String) {
        let dialog = ApprovalDialogComponent(presentation: presentation, approvalID: approvalID)
        overlayHost.show(dialog)
    }

    public func messageCount() -> Int {
        transcript.messages.count
    }

    public func renderOverlay(width: Int) -> [String] {
        overlayHost.render(width: width)
    }

    private func handleInput(_ data: String) async {
        if data == "\r" {
            _ = submitComposer()
            renderFrame()
            return
        }
        composer.handleInput(data)
        updateAutocomplete()
        renderFrame()
    }

    private func handleResize(columns: Int, rows: Int) async {
        transcript.viewportRows = max(1, rows - 6)
        renderFrame(full: true)
    }

    private func updateOrchestration(_ state: ConversationOrchestrationState) async {
        statusLine.phase = state.agenticPhase.rawValue
        statusLine.showSpinner = state.agenticPhase != .idle && state.agenticPhase != .completed
        renderFrame()
    }

    private func handleSurfaceIntent(_ intent: ClientSurfaceIntent) async {
        if intent.kind == .execApprovalRequired, let presentation = intent.presentation {
            showApproval(presentation, approvalID: intent.approvalID ?? "unknown")
        }
    }

    private func updateAutocomplete() {
        let text = composer.text
        guard text.hasPrefix("/") else {
            composer.autocomplete = nil
            return
        }
        let prefix = String(text.dropFirst().split(separator: " ").first ?? "")
        let suggestions = AutocompletePopupComponent.slashSuggestions(
            registry: controlInputBridge.registry,
            prefix: prefix
        )
        composer.autocomplete = AutocompletePopupComponent(suggestions: suggestions)
    }

    private func renderFrame(full: Bool = false) {
        let width = terminal.columns
        renderer.render(
            component: overlayHost,
            width: width,
            context: "TUIApp",
            changeAboveViewport: full
        )
    }
}
