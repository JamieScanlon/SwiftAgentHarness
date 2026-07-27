import Foundation

/// Event loop driving the TUI surface from runtime streams.
///
/// Rendering and input are owned here; everything that leaves the surface leaves through
/// ``TUIAppHost``. Set a host with ``setHost(_:)`` before ``start()`` — without one the
/// composer still edits but submissions have nowhere to go.
public actor TUIApp {
    public let terminal: any Terminal
    public let renderer: DifferentialRenderer

    // Component tree is actor-owned and deliberately not `public`: these are
    // non-`Sendable` reference types, and handing them out across the isolation
    // boundary invites off-actor mutation of the render tree. Value snapshots are
    // exposed through the accessors below instead.
    var transcript: TranscriptListComponent
    var composer: InputComposerComponent
    var statusLine: StatusLineComponent
    var toolPane: ToolPaneViewComponent
    var reasoningView: ReasoningViewComponent
    var overlayHost: OverlayHostComponent
    var splitView: SplitComponent
    var controlInputBridge: TUIControlInputBridge

    private var streamingSink: TUIStreamingSurfaceSink?
    private var streamingEngine: StreamingSurfaceEngine?

    /// Strongly held: a weak host silently deallocates when the caller builds one inline,
    /// turning every submission into a no-op with no diagnostic. Released by ``stop()``,
    /// so a host that retains the app should call it.
    private var host: (any TUIAppHost)?
    private var running = false
    private var turnActive = false
    private var accumulatedTurnText = ""
    private var activeApprovalID: String?
    private var keyDecoder = TUIKeyDecoder()
    /// Invoked when a mode dialog selection is confirmed.
    private var onModeSelected: (@Sendable (ModeOption) -> Void)?
    private var inputTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var turnGeneration = 0
    private var surfaceRegistration: TUISurfaceRegistration?
    private var fileCompleter: FilePathCompleter?
    private var autocompleteToken: AutocompleteToken?

    /// The token an open autocomplete popup is completing, so acceptance replaces exactly
    /// that span instead of guessing at the buffer's shape.
    private struct AutocompleteToken {
        var kind: AutocompleteKind
        var lineIndex: Int
        /// Grapheme offset of the token's first character, including its sigil.
        var start: Int
        /// The whole token, which is what acceptance replaces. Ending it at the cursor
        /// instead would leave the tail behind: completing `@No|tes` would yield
        /// `@Notes.mdtes`.
        var length: Int
        /// Prefix up to the cursor, which is what the completer is queried with.
        var queryLength: Int
    }
    private var submissionContinuations: [UUID: AsyncStream<ComposerSubmission>.Continuation] = [:]

    private nonisolated let pasteInput = BracketedPasteAccumulatorBox()
    private nonisolated let inputChannel = InputChannelBox()

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
        self.overlayHost = OverlayHostComponent(
            base: StackComponent(focusedIndex: 2, children: [splitView, statusLine, composer])
        )
    }

    // MARK: - Host

    public func setHost(_ host: any TUIAppHost) {
        self.host = host
    }

    public func setOnModeSelected(_ handler: @escaping @Sendable (ModeOption) -> Void) {
        onModeSelected = handler
    }

    /// Enables `@`-triggered file completion rooted at `url`.
    ///
    /// Off until a host opts in: the completer walks the filesystem, and the surface has
    /// no business guessing which directory is the workspace.
    public func setFileCompletionRoot(_ url: URL?, maximumResults: Int = 20) {
        fileCompleter = url.map { FilePathCompleter(root: $0, maximumResults: maximumResults) }
    }

    /// Async-sequence alternative to a delegate: every composer submission is yielded here.
    public func submissions() -> AsyncStream<ComposerSubmission> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ComposerSubmission>.makeStream(of: ComposerSubmission.self)
        submissionContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeSubmissionContinuation(id)
            }
        }
        return stream
    }

    private func removeSubmissionContinuation(_ id: UUID) {
        submissionContinuations.removeValue(forKey: id)
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !running else { return }
        running = true
        configureStreamingIfNeeded()
        await refreshSlashCommandRegistry()

        installOverlayDismissHandler()

        // One serial consumer. Spawning a `Task` per read (the previous shape) gives up
        // ordering between reads: Swift guarantees nothing about the relative start of
        // independently created tasks, so a fast paste could transpose characters, or
        // deliver Enter before the text it was meant to submit.
        let stream = inputChannel.open()
        inputTask = Task { [weak self] in
            for await chunk in stream {
                await self?.handleInputChunk(chunk)
            }
        }

        terminal.start(
            onInput: { [weak self] data in
                guard let self else { return }
                for chunk in self.pasteInput.feed(data) {
                    self.inputChannel.send(chunk)
                }
            },
            onResize: { [weak self] columns, rows in
                Task { [weak self] in
                    await self?.handleResize(columns: columns, rows: rows)
                }
            }
        )

        // Rendered synchronously: deferring the first paint into a detached task races
        // the input consumer and makes `await app.start()` return before anything is drawn.
        renderFrame(full: true)
    }

    public func stop() {
        running = false
        inputChannel.close()
        inputTask?.cancel()
        inputTask = nil
        turnTask?.cancel()
        turnTask = nil
        for continuation in submissionContinuations.values { continuation.finish() }
        submissionContinuations.removeAll()
        host = nil
        if let registration = surfaceRegistration {
            surfaceRegistration = nil
            // Fire-and-forget: `stop()` is synchronous, and leaving a stale deliverer in
            // the process-global registry would keep this app alive after shutdown.
            Task { await registration.unregister() }
        }
        terminal.stop()
    }

    // MARK: - Snapshots

    public func messageCount() -> Int { transcript.messages.count }
    public func transcriptMessages() -> [TUIMessage] { transcript.messages }
    public func composerText() -> String { composer.text }
    public func composerSubmissionText() -> String { composer.expandedText }
    public func hasOverlay() -> Bool { overlayHost.hasOverlay }
    public func hasAutocompleteSuggestions() -> Bool {
        !(composer.autocomplete?.suggestions.isEmpty ?? true)
    }
    public func statusPhase() -> String { statusLine.phase }
    public func isTurnActive() -> Bool { turnActive }
    public func renderOverlay(width: Int) -> [String] { overlayHost.render(width: width) }
    public func renderFrameLines(width: Int) -> [String] { overlayHost.render(width: width) }

    public func setStatus(modelName: String?, tokenCount: Int?) {
        statusLine.modelName = modelName
        statusLine.tokenCount = tokenCount
        renderFrame()
    }

    // MARK: - Streaming ingestion

    private func configureStreamingIfNeeded() {
        guard streamingSink == nil else { return }
        let sink = TUIStreamingSurfaceSink { [weak self] mutation in
            await self?.applyStreamingMutation(mutation)
        }
        streamingSink = sink
        streamingEngine = StreamingSurfaceEngine(capabilities: .terminal, sink: sink)
    }

    private func applyStreamingMutation(_ mutation: TUIStreamingSurfaceSink.TranscriptMutation) {
        switch mutation {
        case .tokenDelta(let text):
            TUIStreamingSurfaceSinkLogic.sendTokenDelta(text, to: transcript)
        case .reasoningDelta(let text):
            reasoningView.append(text)
        case .final(let payload):
            TUIStreamingSurfaceSinkLogic.sendFinal(payload, to: transcript)
        case .cancellation(let notice):
            TUIStreamingSurfaceSinkLogic.emitCancellation(notice, to: transcript)
        case .previewCommit:
            TUIStreamingSurfaceSinkLogic.commitPreview(to: transcript)
        }
    }

    public func ingest(_ partial: ChatStreamingPartial) async {
        configureStreamingIfNeeded()
        turnActive = true
        await streamingEngine?.ingest(partial)
        switch partial {
        case .text(let text):
            accumulatedTurnText += text
        case .toolCall(let toolName, _, let fragment, _):
            toolPane.updateToolCall(name: toolName, fragment: fragment)
        case .toolCallStarted(let toolName, _, _), .toolCallCompleted(let toolName, _, _, _):
            toolPane.updateToolCall(name: toolName, fragment: nil)
        case .surfaceIntent(let intent):
            await handleSurfaceIntent(intent)
        case .reasoning:
            // Routed through the streaming engine so reasoning inherits pacing,
            // coalescing and cancellation like every other stream.
            break
        }
        statusLine.advanceSpinner()
        renderFrame()
    }

    public func finishTurn(final: StreamingFinalPayload) async {
        configureStreamingIfNeeded()
        await streamingEngine?.finish(final: final)
        turnActive = false
        accumulatedTurnText = ""
        statusLine.showSpinner = false
        statusLine.phase = "idle"
        renderFrame()
    }

    /// Finishes using the text accumulated from this turn's partials.
    public func finishTurn() async {
        await finishTurn(final: StreamingFinalPayload(text: accumulatedTurnText))
    }

    public func cancelTurn() async {
        configureStreamingIfNeeded()
        await streamingEngine?.cancel()
        turnActive = false
        statusLine.showSpinner = false
        statusLine.phase = "cancelled"
        renderFrame()
    }

    public func flushSegment() async {
        configureStreamingIfNeeded()
        await streamingEngine?.flushSegment()
        renderFrame()
    }

    /// Drives the surface from a live ``ChatStreamResponse``.
    public func consume(_ response: ChatStreamResponse) async {
        await consume(partials: response.partialContent, orchestration: response.orchestrationState)
    }

    public func consume(
        partials: AsyncStream<ChatStreamingPartial>,
        orchestration: AsyncStream<ConversationOrchestrationState>
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
        // A cancelled turn already painted its terminal state; finishing here would race
        // "cancelled" back to "idle" and re-enable a spinner nothing is driving.
        guard !Task.isCancelled else { return }
        await finishTurn()
    }

    @available(*, deprecated, message: "Requires the final payload up front, so it cannot be driven from a live event stream. Use consume(_:) or attach TUIRunStreamingService.")
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

    public func updateOrchestration(_ state: ConversationOrchestrationState) async {
        statusLine.phase = state.agenticPhase.rawValue
        // `tokenCount` was a dead field until now; the orchestration snapshot already
        // carries the numbers the status line was designed to show.
        if let promptTokens = state.promptTokens {
            statusLine.tokenCount = promptTokens
        }
        // Only overwrite when present: auxiliary snapshots omit these fields, and an
        // unconditional assignment makes the status line flicker between forms.
        if let contextLimit = state.contextLimitTokens {
            statusLine.contextLimitTokens = contextLimit
        }
        statusLine.showSpinner = state.agenticPhase != .idle && state.agenticPhase != .completed
        turnActive = statusLine.showSpinner
        statusLine.advanceSpinner()
        renderFrame()
    }

    /// Renders a delivered portable presentation into the transcript.
    ///
    /// The entry point `TUIMessageOutputDeliverer` calls. `content` keeps the text floor so
    /// the message still reads correctly anywhere the presentation can't be used.
    public func deliver(presentation: MessagePresentation) {
        // The `message` tool commits mid-turn, while an assistant message is still
        // streaming. Appending a finished message on top of a streaming one strands
        // `activeStreamingView()`, so the remaining tokens open a *third* message and
        // `sendFinal` then writes the whole turn's text into it — showing the pre-tool
        // prose twice. Commit the in-flight message first and restart the accumulator.
        if let active = transcript.activeStreamingView() {
            active.commitStreaming()
            transcript.syncMessage(from: active)
            accumulatedTurnText = ""
        }
        transcript.appendMessage(
            TUIMessage(
                role: .assistant,
                content: TUITextSanitizer.sanitizeMultiline(presentation.textFallback()),
                presentation: presentation
            )
        )
        renderFrame()
    }

    /// The terminal surface's plugin record.
    public nonisolated let surfacePlugin = TUISurfacePlugin()

    /// Registers this surface with the core delivery registry.
    ///
    /// Explicit rather than automatic in ``start()``: `MessageOutputDeliveryRegistry` is
    /// process-global and holds the deliverer — and therefore this app — until released,
    /// so the host owns the lifetime. Without it, committed `message`-tool output for
    /// TUI-originated turns is dropped and every structured message degrades to its text
    /// fallback.
    public func registerSurface(conversationID: UUID? = nil) async {
        let registration = TUISurfaceRegistration(plugin: surfacePlugin)
        surfaceRegistration = registration
        await registration.register(app: self, conversationID: conversationID)
    }

    public func unregisterSurface() async {
        guard let registration = surfaceRegistration else { return }
        surfaceRegistration = nil
        await registration.unregister()
    }

    // MARK: - Submission

    @discardableResult
    public func submitComposer() -> ComposerSubmission {
        let submission = composer.makeSubmission()
        // Echo the buffer as the user saw it — with large pastes still collapsed to their
        // placeholder — while submitting the expanded text. Echoing `submission.text`
        // would dump the whole 400-line paste the placeholder exists to avoid.
        let displayText = composer.text
        if shouldEchoInTranscript(submission) {
            transcript.appendMessage(TUIMessage(role: .user, content: displayText))
        }
        composer.clear()
        clearAutocomplete()
        return submission
    }

    /// Local *presentation* classification only.
    ///
    /// Never used to dispatch: `SlashCommandDispatchService.processControlInputBoundary`
    /// runs inside the send path with the conversation-scoped registry and real owner
    /// authorization. This exists so the surface can decide whether to echo the line.
    public func classifySubmission(_ submission: ComposerSubmission) -> ControlInputClassification {
        controlInputBridge.classify(submission)
    }

    /// Control-only input is never shown as a user message; the boundary strips it before
    /// the model ever sees it, and echoing it here contradicts that contract.
    private func shouldEchoInTranscript(_ submission: ComposerSubmission) -> Bool {
        guard !submission.text.isEmpty else { return false }
        switch controlInputBridge.classify(submission) {
        case .command, .directiveOnly:
            return false
        default:
            return true
        }
    }

    private func submitFromComposer() async {
        guard !composer.isEmpty else { return }
        let submission = submitComposer()
        for continuation in submissionContinuations.values {
            continuation.yield(submission)
        }
        renderFrame()

        guard let host else { return }
        do {
            if let response = try await host.submit(submission) {
                // Consumed on its own task. Awaiting it here would park the single serial
                // input consumer for the whole turn, so no keystroke could be decoded
                // while the model streams — including the Ctrl-C that is meant to cancel
                // it, and which raw mode leaves as the only way out.
                startTurn(consuming: response)
            }
        } catch {
            transcript.appendMessage(
                TUIMessage(role: .system, content: "Send failed: \(error)")
            )
            renderFrame()
        }
    }

    /// Consumes a response on a detached task so the input loop keeps draining.
    private func startTurn(consuming response: ChatStreamResponse) {
        turnTask?.cancel()
        turnGeneration += 1
        let generation = turnGeneration
        // Marked active at the point the turn starts, not at the first partial: Ctrl-C
        // between the send and the first token must still cancel rather than quit.
        turnActive = true
        statusLine.showSpinner = true
        turnTask = Task { [weak self] in
            await self?.consume(response)
            await self?.clearTurnTask(generation: generation)
        }
    }

    /// Clears the handle only if it still belongs to this turn. A cancelled turn unwinds
    /// asynchronously, so without the generation check it can land after the *next* turn
    /// started and drop that turn's handle — leaving a later Ctrl-C with nothing to cancel.
    private func clearTurnTask(generation: Int) {
        guard generation == turnGeneration else { return }
        turnTask = nil
    }

    /// Awaits the in-flight turn. Intended for tests and for hosts shutting down.
    public func waitForTurn() async {
        await turnTask?.value
    }

    // MARK: - Input routing

    private func handleInputChunk(_ chunk: String) async {
        for key in keyDecoder.decode(chunk) {
            await handle(key)
        }
    }

    /// Exposed for tests and for hosts that drive input themselves.
    public func handleKey(_ key: TUIKey) async {
        await handle(key)
    }

    /// Decodes and routes a raw terminal chunk. Prefer ``handleKey(_:)`` in tests.
    public func handleRawInput(_ data: String) async {
        for chunk in pasteInput.feed(data) {
            await handleInputChunk(chunk)
        }
    }

    private func handle(_ key: TUIKey) async {
        // Interrupt and quit are checked before overlay capture. `rawInput` is nil for
        // both, so routing them into a dialog would drop them — and with ISIG cleared
        // there is no signal fallback, leaving a modal that cannot be escaped.
        if case .interrupt = key {
            await handleInterrupt()
            return
        }
        if case .endOfTransmission = key, composer.isEmpty, !overlayHost.hasOverlay {
            await host?.quit()
            return
        }

        // Overlays capture the rest. Routing straight to the composer — the previous
        // behaviour — left approval dialogs decorative: Enter submitted the composer
        // underneath the modal and Esc never reached the dismiss path.
        if overlayHost.hasOverlay {
            await handleOverlayKey(key)
            renderFrame()
            return
        }

        switch key {
        case .interrupt, .endOfTransmission:
            return
        case .enter:
            await submitFromComposer()
            return
        case .newline:
            composer.insertNewline()
        case .paste(let paste):
            composer.insertPaste(paste)
        case .tab:
            // Returns early: the trailing `updateAutocomplete()` would immediately
            // re-derive the popup from the buffer and undo both of these.
            acceptAutocompleteSuggestion()
            renderFrame()
            return
        case .up where composer.autocomplete?.suggestions.isEmpty == false:
            moveAutocompleteSelection(-1)
        case .down where composer.autocomplete?.suggestions.isEmpty == false:
            moveAutocompleteSelection(1)
        case .escape:
            clearAutocomplete()
            renderFrame()
            return
        case .pageUp:
            transcript.scrollBy(-max(1, terminal.rows / 2))
        case .pageDown:
            transcript.scrollBy(max(1, terminal.rows / 2))
        default:
            if let raw = key.rawInput {
                composer.handleInput(raw)
            }
        }

        updateAutocomplete()
        renderFrame()
    }

    private func handleOverlayKey(_ key: TUIKey) async {
        if case .escape = key {
            await dismissOverlayByUser()
            return
        }
        guard let raw = key.rawInput else { return }
        overlayHost.handleInput(raw)

        if let dialog = overlayHost.overlay as? ApprovalDialogComponent,
           let decision = dialog.takeDecision() {
            await completeApproval(approvalID: dialog.approvalID, actionID: decision)
            return
        }
        if let dialog = overlayHost.overlay as? ModeDialogComponent,
           let option = dialog.takeSelection() {
            onModeSelected?(option)
            overlayHost.dismissOverlay()
        }
    }

    private func handleInterrupt() async {
        if overlayHost.hasOverlay {
            await dismissOverlayByUser()
            return
        }
        // Ctrl-C cancels an in-flight turn; on an idle surface it quits. Raw mode clears
        // ISIG, so this byte is the only quit path the user has.
        if turnActive {
            turnTask?.cancel()
            turnTask = nil
            await host?.cancelTurn()
            await cancelTurn()
            return
        }
        if !composer.isEmpty {
            composer.clear()
            clearAutocomplete()
            renderFrame()
            return
        }
        await host?.quit()
    }

    private func handleResize(columns: Int, rows: Int) async {
        transcript.viewportRows = max(1, rows - 6)
        renderFrame(full: true)
    }

    private func installOverlayDismissHandler() {
        guard overlayHost.onOverlayDismissed == nil else { return }
        overlayHost.onOverlayDismissed = { [weak self] in
            Task { [weak self] in
                await self?.restoreComposerFocus()
            }
        }
    }

    private func restoreComposerFocus() {
        activeApprovalID = nil
        composer.isFocused = true
        renderFrame()
    }

    // MARK: - Approvals

    public func showApproval(_ presentation: ApprovalPresentation, approvalID: String) {
        installOverlayDismissHandler()
        let dialog = ApprovalDialogComponent(presentation: presentation, approvalID: approvalID)
        activeApprovalID = approvalID
        composer.isFocused = false
        overlayHost.show(dialog)
        renderFrame()
    }

    /// User-initiated dismissal.
    ///
    /// An approval dismissed without a decision would leave the runtime blocked on an
    /// approval the user believes they closed, with no way to bring the modal back. Treat
    /// it as a denial — the safe reading of "the user closed the permission prompt".
    private func dismissOverlayByUser() async {
        if let dialog = overlayHost.overlay as? ApprovalDialogComponent {
            await host?.resolveApproval(
                approvalID: dialog.approvalID,
                actionID: ApprovalDecision.deny.rawValue
            )
        }
        overlayHost.dismissOverlay()
        renderFrame()
    }

    private func completeApproval(approvalID: String, actionID: String) async {
        await host?.resolveApproval(approvalID: approvalID, actionID: actionID)
        overlayHost.dismissOverlay()
    }

    /// Presents a mode picker as a modal overlay. `ModeDialogComponent` existed but was
    /// never instantiated anywhere in the package.
    public func showModeDialog(title: String, options: [ModeOption], selectedIndex: Int = 0) {
        installOverlayDismissHandler()
        let dialog = ModeDialogComponent(title: title, options: options, selectedIndex: selectedIndex)
        composer.isFocused = false
        overlayHost.show(dialog)
        renderFrame()
    }

    public func dismissApproval(approvalID: String?) {
        guard overlayHost.hasOverlay else { return }
        if let approvalID, let active = activeApprovalID, approvalID != active { return }
        overlayHost.dismissOverlay()
    }

    private func handleSurfaceIntent(_ intent: ClientSurfaceIntent) async {
        switch intent.kind {
        case .execApprovalRequired:
            guard let presentation = intent.presentation else { return }
            showApproval(presentation, approvalID: intent.approvalID ?? "unknown")
        case .execApprovalCleared:
            // Resolved elsewhere (another surface, an expiry). Without this the modal
            // stays on screen forever with no way to dismiss it.
            dismissApproval(approvalID: intent.approvalID)
        case .openFileForEdit:
            break
        }
    }

    // MARK: - Autocomplete

    private func refreshSlashCommandRegistry() async {
        guard let registry = await host?.slashCommandRegistry() else { return }
        controlInputBridge.registry = registry
    }

    /// Finds the token under the cursor that can be completed, if any.
    ///
    /// Slash commands complete only as the first token of the first line — mid-message
    /// `/` is just a slash. File paths complete after an `@` that begins a word, which is
    /// what makes the trigger unambiguous.
    private func currentAutocompleteToken() -> AutocompleteToken? {
        let lineIndex = composer.cursorLine
        guard lineIndex >= 0, lineIndex < composer.lines.count else { return nil }
        let characters = Array(composer.lines[lineIndex])
        let column = max(0, min(composer.cursorColumn, characters.count))

        if lineIndex == 0, characters.first == "/" {
            let end = characters.firstIndex(of: " ") ?? characters.count
            if column <= end {
                return AutocompleteToken(
                    kind: .slashCommand,
                    lineIndex: 0,
                    start: 0,
                    length: end,
                    queryLength: column
                )
            }
        }

        var index = column - 1
        while index >= 0 {
            let character = characters[index]
            if character == " " || character == "\t" { return nil }
            if character == "@" {
                let startsWord = index == 0 || characters[index - 1] == " " || characters[index - 1] == "\t"
                guard startsWord else { return nil }
                var wordEnd = column
                while wordEnd < characters.count,
                      characters[wordEnd] != " ",
                      characters[wordEnd] != "\t" {
                    wordEnd += 1
                }
                return AutocompleteToken(
                    kind: .filePath,
                    lineIndex: lineIndex,
                    start: index,
                    length: wordEnd - index,
                    queryLength: column - index
                )
            }
            index -= 1
        }
        return nil
    }

    private func updateAutocomplete() {
        guard let token = currentAutocompleteToken() else {
            clearAutocomplete()
            return
        }
        let raw = Self.substring(
            composer.lines[token.lineIndex],
            from: token.start,
            length: token.queryLength
        )

        let suggestions: [AutocompleteSuggestion]
        switch token.kind {
        case .slashCommand:
            suggestions = AutocompletePopupComponent.slashSuggestions(
                registry: controlInputBridge.registry,
                prefix: raw
            )
        case .filePath:
            guard let fileCompleter else {
                clearAutocomplete()
                return
            }
            suggestions = AutocompletePopupComponent.fileSuggestions(
                completer: fileCompleter,
                token: String(raw.dropFirst())
            )
        }

        guard !suggestions.isEmpty else {
            clearAutocomplete()
            return
        }
        let previous = composer.autocomplete?.selectedIndex ?? 0
        autocompleteToken = token
        composer.autocomplete = AutocompletePopupComponent(
            suggestions: suggestions,
            selectedIndex: max(0, min(previous, suggestions.count - 1)),
            kind: token.kind
        )
    }

    private func clearAutocomplete() {
        autocompleteToken = nil
        composer.autocomplete = nil
    }

    private func moveAutocompleteSelection(_ delta: Int) {
        guard var popup = composer.autocomplete, !popup.suggestions.isEmpty else { return }
        let count = popup.suggestions.count
        popup.selectedIndex = ((popup.selectedIndex + delta) % count + count) % count
        composer.autocomplete = popup
    }

    /// Substitutes the completed token, and only that token.
    private func acceptAutocompleteSuggestion() {
        guard let popup = composer.autocomplete,
              popup.selectedIndex >= 0,
              popup.selectedIndex < popup.suggestions.count,
              let token = autocompleteToken,
              token.lineIndex >= 0,
              token.lineIndex < composer.lines.count else { return }

        var insertion = popup.suggestions[popup.selectedIndex].insertionText
        var characters = Array(composer.lines[token.lineIndex])
        let start = max(0, min(token.start, characters.count))
        let end = max(start, min(token.start + token.length, characters.count))
        // Don't double the separator when the token is already followed by one.
        if insertion.hasSuffix(" "), end < characters.count, characters[end] == " " {
            insertion.removeLast()
        }
        characters.replaceSubrange(start..<end, with: Array(insertion))

        composer.lines[token.lineIndex] = String(characters)
        composer.cursorLine = token.lineIndex
        composer.cursorColumn = start + insertion.count
        clearAutocomplete()
    }

    private static func substring(_ line: String, from start: Int, length: Int) -> String {
        let characters = Array(line)
        let lower = max(0, min(start, characters.count))
        let upper = max(lower, min(start + length, characters.count))
        return String(characters[lower..<upper])
    }

    // MARK: - Rendering

    private func renderFrame(full: Bool = false) {
        let width = terminal.columns
        guard width > 0 else { return }
        renderer.render(
            component: overlayHost,
            width: width,
            context: "TUIApp",
            changeAboveViewport: full
        )
    }
}

/// Serializes terminal reads onto one ordered stream.
///
/// `nonisolated` and lock-guarded because the terminal's read callback fires on a
/// dispatch queue, outside the actor.
final class InputChannelBox: @unchecked Sendable {
    private var continuation: AsyncStream<String>.Continuation?
    private let lock = NSLock()

    func open() -> AsyncStream<String> {
        let (stream, newContinuation) = AsyncStream<String>.makeStream(of: String.self)
        lock.lock()
        continuation?.finish()
        continuation = newContinuation
        lock.unlock()
        return stream
    }

    func send(_ value: String) {
        lock.lock()
        let target = continuation
        lock.unlock()
        target?.yield(value)
    }

    func close() {
        lock.lock()
        let target = continuation
        continuation = nil
        lock.unlock()
        target?.finish()
    }
}
