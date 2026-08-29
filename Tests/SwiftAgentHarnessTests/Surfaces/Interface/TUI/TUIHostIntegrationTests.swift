import Foundation
import Testing
@testable import SwiftAgentHarness

/// End-to-end coverage of the host seam: keystroke → envelope → host → stream → frame,
/// and approval intent → keystroke → decision → dismissal.
///
/// Before this seam existed there was no test anywhere that delivered a keystroke to a
/// `TUIApp` at all, which is how a discarded submission and an inoperable approval
/// dialog both survived to release.
@Suite("TUIApp host integration")
struct TUIAppHostIntegrationTests {
    // MARK: Submission

    @Test("Enter delivers the composer envelope to the host")
    func enterSubmits() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        await app.handleKey(.text("hello world"))
        await app.handleKey(.enter)

        #expect(recorder.submissions.map(\.text) == ["hello world"])
        #expect(await app.composerText().isEmpty)
    }

    @Test("Enter on an empty composer submits nothing")
    func emptyEnterIsIgnored() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        await app.handleKey(.enter)

        #expect(recorder.submissions.isEmpty)
        #expect(await app.messageCount() == 0)
    }

    @Test("Submissions carry composer provenance")
    func submissionProvenance() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        let envelope = BracketedPaste.start + "a\nb" + BracketedPaste.end
        await app.handleRawInput(envelope)
        await app.handleKey(.enter)

        #expect(recorder.submissions.first?.provenance.wasPasted == true)
        #expect(recorder.submissions.first?.provenance.originSurface == "tui")
        #expect(recorder.submissions.first?.text == "a\nb")
    }

    @Test("A normal message is echoed into the transcript")
    func normalMessageEchoed() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        await app.handleKey(.text("what is this"))
        await app.handleKey(.enter)

        let messages = await app.transcriptMessages()
        #expect(messages.contains { $0.role == .user && $0.content == "what is this" })
    }

    @Test("Control-only input is not echoed as a user message")
    func controlInputNotEchoed() async {
        // The core boundary strips control input before the model sees it; echoing it as
        // a user turn in the surface contradicts that contract.
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        await app.handleKey(.text("/help"))
        await app.handleKey(.enter)

        let messages = await app.transcriptMessages()
        #expect(!messages.contains { $0.role == .user && $0.content.contains("/help") })
        // …but it still reaches the host, which is where classification actually happens.
        #expect(recorder.submissions.map(\.text) == ["/help"])
    }

    @Test("Submissions are also published on the async stream")
    func submissionStream() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        let stream = await app.submissions()

        let collector = Task { () -> String? in
            for await submission in stream { return submission.text }
            return nil
        }

        await app.handleKey(.text("streamed"))
        await app.handleKey(.enter)

        let received = await collector.value
        #expect(received == "streamed")
        collector.cancel()
    }

    // MARK: Streaming

    @Test("A host response streams into the transcript")
    func responseStreamsIntoTranscript() async {
        let terminal = VirtualTerminal(columns: 60, rows: 12)
        let app = TUIApp(terminal: terminal)
        let response = Self.makeResponse(text: ["Hel", "lo"])
        let host = ClosureTUIAppHost(submit: { _ in response })
        await app.setHost(host)

        await app.handleKey(.text("hi"))
        await app.handleKey(.enter)
        await app.waitForTurn()

        let messages = await app.transcriptMessages()
        #expect(messages.contains { $0.role == .assistant && $0.content == "Hello" })
        #expect(await app.isTurnActive() == false)
    }

    @Test("Token deltas reach the transcript before the turn finishes")
    func tokensAppearWhileStreaming() async {
        // Asserting only the final content would pass even if no delta ever arrived,
        // because `sendFinal` sets the content outright.
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.ingest(.text("partial output"))
        let mid = await app.transcriptMessages()
        #expect(mid.contains { $0.role == .assistant })
        #expect(await app.isTurnActive())
    }

    @Test("Input stays responsive while a turn streams")
    func inputResponsiveDuringTurn() async {
        // The serial input consumer used to await the whole turn inline, so no keystroke
        // could be decoded until the model finished — including the cancel.
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        let (partials, partialContinuation) = AsyncStream<ChatStreamingPartial>.makeStream(
            of: ChatStreamingPartial.self
        )
        let (orchestration, orchestrationContinuation) = AsyncStream<ConversationOrchestrationState>.makeStream(
            of: ConversationOrchestrationState.self
        )
        let response = ChatStreamResponse(
            partialContent: partials,
            orchestrationState: orchestration,
            conversationID: UUID()
        )
        await app.setHost(recorder.makeHost(response: response))

        await app.handleKey(.text("go"))
        await app.handleKey(.enter)
        #expect(await app.isTurnActive())

        // The stream is still open; the interrupt must be processed anyway.
        await app.handleKey(.interrupt)
        #expect(await app.statusPhase() == "cancelled")
        #expect(recorder.cancelCount == 1)

        partialContinuation.finish()
        orchestrationContinuation.finish()
    }

    @Test("A failing send surfaces as a system message")
    func failedSendIsReported() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        let host = ClosureTUIAppHost(submit: { _ in throw TestHostError.boom })
        await app.setHost(host)

        await app.handleKey(.text("hi"))
        await app.handleKey(.enter)
        await app.waitForTurn()

        let messages = await app.transcriptMessages()
        #expect(messages.contains { $0.role == .system && $0.content.contains("Send failed") })
    }

    // MARK: Approvals

    @Test("Approval overlay can be operated and resolved from the keyboard")
    func approvalResolves() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 80, rows: 20))
        await app.setHost(recorder.makeHost())

        await app.ingest(.surfaceIntent(ClientSurfaceIntent(
            kind: .execApprovalRequired,
            approvalID: "a1",
            presentation: ApprovalPresentation.standard(title: "Run command?")
        )))
        #expect(await app.hasOverlay())

        await app.handleKey(.right)
        await app.handleKey(.enter)

        #expect(recorder.approvals.count == 1)
        #expect(recorder.approvals.first?.0 == "a1")
        #expect(recorder.approvals.first?.1 == ApprovalDecision.allowAlways.rawValue)
        #expect(await app.hasOverlay() == false)
    }

    @Test("Enter on the default button resolves allow-once")
    func approvalDefaultButton() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 80, rows: 20))
        await app.setHost(recorder.makeHost())

        await app.showApproval(ApprovalPresentation.standard(title: "Run?"), approvalID: "a2")
        await app.handleKey(.enter)

        #expect(recorder.approvals.first?.1 == ApprovalDecision.allowOnce.rawValue)
    }

    @Test("An overlay captures Enter instead of submitting the composer")
    func overlayCapturesEnter() async {
        // With input routed straight to the composer, Enter while a modal was up
        // submitted whatever was underneath it.
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 80, rows: 20))
        await app.setHost(recorder.makeHost())

        await app.handleKey(.text("draft message"))
        await app.showApproval(ApprovalPresentation.standard(title: "Run?"), approvalID: "a3")
        await app.handleKey(.enter)

        #expect(recorder.submissions.isEmpty)
        #expect(await app.composerText() == "draft message")
    }

    @Test("Escape dismisses an approval overlay")
    func escapeDismissesOverlay() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 80, rows: 20))
        await app.showApproval(ApprovalPresentation.standard(title: "Run?"), approvalID: "a4")
        #expect(await app.hasOverlay())
        await app.handleKey(.escape)
        #expect(await app.hasOverlay() == false)
    }

    @Test("Dismissing an approval resolves it as a denial")
    func dismissDenies() async {
        // Silently dropping the modal would leave the runtime blocked on an approval the
        // user believes they closed, with no way to bring it back.
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 80, rows: 20))
        await app.setHost(recorder.makeHost())
        await app.showApproval(ApprovalPresentation.standard(title: "Run?"), approvalID: "a7")
        await app.handleKey(.escape)
        #expect(recorder.approvals.first?.1 == ApprovalDecision.deny.rawValue)
        #expect(await app.hasOverlay() == false)
    }

    @Test("Ctrl-C over an approval resolves it as a denial")
    func interruptOverApprovalDenies() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 80, rows: 20))
        await app.setHost(recorder.makeHost())
        await app.showApproval(ApprovalPresentation.standard(title: "Run?"), approvalID: "a8")
        await app.handleKey(.interrupt)
        #expect(recorder.approvals.first?.1 == ApprovalDecision.deny.rawValue)
        #expect(recorder.quitCount == 0)
        #expect(await app.hasOverlay() == false)
    }

    @Test("Escape dismisses the autocomplete popup")
    func escapeDismissesAutocomplete() async {
        // The trailing `updateAutocomplete()` used to re-derive the popup straight after
        // Escape cleared it, so it could never be dismissed.
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.handleKey(.text("/hel"))
        #expect(await app.hasAutocompleteSuggestions())
        await app.handleKey(.escape)
        #expect(await app.hasAutocompleteSuggestions() == false)
    }

    @Test("An approval cleared elsewhere dismisses the modal")
    func clearedIntentDismisses() async {
        // Otherwise a modal resolved on another surface stays on screen forever.
        let app = TUIApp(terminal: VirtualTerminal(columns: 80, rows: 20))
        await app.ingest(.surfaceIntent(ClientSurfaceIntent(
            kind: .execApprovalRequired,
            approvalID: "a5",
            presentation: ApprovalPresentation.standard(title: "Run?")
        )))
        #expect(await app.hasOverlay())

        await app.ingest(.surfaceIntent(ClientSurfaceIntent(kind: .execApprovalCleared, approvalID: "a5")))
        #expect(await app.hasOverlay() == false)
    }

    @Test("Focus moves to the dialog and back to the composer")
    func focusFollowsOverlay() async {
        let terminal = VirtualTerminal(columns: 80, rows: 20)
        let app = TUIApp(terminal: terminal)
        await app.showApproval(ApprovalPresentation.standard(title: "Run?"), approvalID: "a6")

        let withOverlay = await app.renderFrameLines(width: 80)
        #expect(CursorMarker.locate(in: withOverlay) != nil)

        await app.handleKey(.escape)
        let afterDismiss = await app.renderFrameLines(width: 80)
        #expect(CursorMarker.locate(in: afterDismiss) != nil)
    }

    // MARK: Mode dialog

    @Test("Mode dialog selection reaches the host callback")
    func modeDialogSelects() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 80, rows: 20))
        let recorder = SelectionRecorder()
        await app.setOnModeSelected { option in recorder.record(option.id) }
        await app.showModeDialog(
            title: "Mode",
            options: [ModeOption(id: "plan", label: "Plan"), ModeOption(id: "build", label: "Build")]
        )
        await app.handleKey(.down)
        await app.handleKey(.enter)

        #expect(recorder.selected == ["build"])
        #expect(await app.hasOverlay() == false)
    }

    // MARK: Lifecycle

    @Test("Ctrl-C cancels an in-flight turn")
    func interruptCancelsTurn() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        await app.ingest(.text("partial"))
        #expect(await app.isTurnActive())

        await app.handleKey(.interrupt)
        #expect(recorder.cancelCount == 1)
        #expect(recorder.quitCount == 0)
        #expect(await app.statusPhase() == "cancelled")
    }

    @Test("Ctrl-C on a non-empty idle composer clears it")
    func interruptClearsComposer() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        await app.handleKey(.text("draft"))
        await app.handleKey(.interrupt)

        #expect(await app.composerText().isEmpty)
        #expect(recorder.quitCount == 0)
    }

    @Test("Ctrl-C on an empty idle composer quits")
    func interruptQuits() async {
        // Raw mode clears ISIG, so this byte is the user's only way out.
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        await app.handleKey(.interrupt)
        #expect(recorder.quitCount == 1)
    }

    @Test("Ctrl-D on an empty composer quits")
    func endOfTransmissionQuits() async {
        let recorder = HostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setHost(recorder.makeHost())

        await app.handleKey(.endOfTransmission)
        #expect(recorder.quitCount == 1)
    }

    // MARK: Autocomplete

    @Test("Tab accepts the selected slash-command suggestion")
    func tabAcceptsSuggestion() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.handleKey(.text("/hel"))
        await app.handleKey(.tab)
        #expect(await app.composerText().hasPrefix("/help"))
    }

    // MARK: Streaming contract

    @Test("TUIApp satisfies the conversation stream consumer contract")
    func consumerConformance() async {
        // The conformance is what `TUIRunStreamingService` and
        // `CommunicationLayerConversationStreamSource.start(driving:)` drive.
        let app = TUIApp(terminal: VirtualTerminal(columns: 40, rows: 10))
        let consumer: any ConversationStreamConsumer = app
        await consumer.ingest(.text("x"))
        await consumer.flushSegment()
        await consumer.finishTurn(final: StreamingFinalPayload(text: "x"))
        #expect(await app.messageCount() == 1)
    }

    @Test("Cancelling through the consumer contract marks the turn cancelled")
    func consumerCancel() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 40, rows: 10))
        let consumer: any ConversationStreamConsumer = app
        await consumer.ingest(.text("partial"))
        await consumer.cancelTurn()
        #expect(await app.statusPhase() == "cancelled")
        #expect(await app.isTurnActive() == false)
    }

    @Test("Reasoning partials do not create a transcript message")
    func reasoningRouted() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 40, rows: 10))
        await app.ingest(.reasoning("thinking about it", blockIndex: 0))
        #expect(await app.messageCount() == 0)
    }

    @Test("Accepting a command leaves room for its argument")
    func tabPreservesArgument() async {
        // Acceptance replaces only the command token, and a command that already has an
        // argument is no longer a completion context.
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.handleKey(.text("/hel"))
        await app.handleKey(.tab)
        #expect(await app.composerText() == "/help ")

        await app.handleKey(.text("verbose"))
        #expect(await app.composerText() == "/help verbose")
        #expect(await app.hasAutocompleteSuggestions() == false)
    }

    @Test("An @ token offers workspace files and completes in place")
    func filePathCompletion() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tui-at-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        manager.createFile(atPath: root.appendingPathComponent("Notes.md").path, contents: Data("x".utf8))

        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setFileCompletionRoot(root)

        await app.handleKey(.text("look at @No"))
        #expect(await app.hasAutocompleteSuggestions())

        await app.handleKey(.tab)
        // Only the token is replaced; the prose around it survives.
        #expect(await app.composerText() == "look at @Notes.md")
        #expect(await app.hasAutocompleteSuggestions() == false)
    }

    @Test("Completing from mid-token replaces the whole token")
    func completesFromMidToken() async throws {
        // Ending the token at the cursor left the tail behind: `@No|tes` completed to
        // `@Notes.mdtes`.
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tui-mid-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        manager.createFile(atPath: root.appendingPathComponent("Notes.md").path, contents: Data("x".utf8))

        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setFileCompletionRoot(root)
        await app.handleKey(.text("@Notes"))
        // Move the cursor back inside the token.
        await app.handleKey(.left)
        await app.handleKey(.left)
        await app.handleKey(.left)
        await app.handleKey(.tab)
        #expect(await app.composerText() == "@Notes.md")
    }

    @Test("Accepting before an existing space does not double it")
    func noDoubleSeparator() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.handleKey(.text("/help extra"))
        // Put the cursor back inside the command token.
        for _ in 0..<6 { await app.handleKey(.left) }
        await app.handleKey(.tab)
        #expect(await app.composerText() == "/help extra")
    }

    @Test("File completion stays off until a host supplies a root")
    func filePathCompletionOptIn() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.handleKey(.text("see @src"))
        #expect(await app.hasAutocompleteSuggestions() == false)
    }

    @Test("An @ mid-word does not trigger completion")
    func atMidWordIsNotATrigger() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tui-at2-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        manager.createFile(atPath: root.appendingPathComponent("Notes.md").path, contents: Data("x".utf8))

        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setFileCompletionRoot(root)
        await app.handleKey(.text("mail me@example"))
        #expect(await app.hasAutocompleteSuggestions() == false)
    }

    @Test("Escape dismisses a file popup too")
    func escapeDismissesFilePopup() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tui-at3-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        manager.createFile(atPath: root.appendingPathComponent("Notes.md").path, contents: Data("x".utf8))

        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
        await app.setFileCompletionRoot(root)
        await app.handleKey(.text("@No"))
        #expect(await app.hasAutocompleteSuggestions())
        await app.handleKey(.escape)
        #expect(await app.hasAutocompleteSuggestions() == false)
    }

    // MARK: Rendering

    @Test("Frames stay within the terminal width while typing and streaming")
    func framesStayBounded() async {
        let terminal = VirtualTerminal(columns: 48, rows: 14)
        let app = TUIApp(terminal: terminal)
        await app.handleKey(.text("a fairly long line of typed input to force wrapping"))
        await app.ingest(.text(String(repeating: "streamed ", count: 20)))

        for line in await app.renderFrameLines(width: 48) {
            #expect(ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line)) <= 48)
        }
    }

    // MARK: Helpers

    private static func makeResponse(text: [String]) -> ChatStreamResponse {
        let (partials, partialContinuation) = AsyncStream<ChatStreamingPartial>.makeStream(
            of: ChatStreamingPartial.self
        )
        let (orchestration, orchestrationContinuation) = AsyncStream<ConversationOrchestrationState>.makeStream(
            of: ConversationOrchestrationState.self
        )
        for fragment in text { partialContinuation.yield(.text(fragment)) }
        partialContinuation.finish()
        orchestrationContinuation.finish()
        return ChatStreamResponse(
            partialContent: partials,
            orchestrationState: orchestration,
            conversationID: UUID()
        )
    }
}

enum TestHostError: Error {
    case boom
}

final class SelectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var selected: [String] {
        lock.withLock { values }
    }
    func record(_ value: String) {
        lock.withLock { values.append(value) }
    }
}

/// Records everything that crosses the host seam.
final class HostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSubmissions: [ComposerSubmission] = []
    private var recordedApprovals: [(String, String)] = []
    private var cancels = 0
    private var quits = 0

    var submissions: [ComposerSubmission] {
        lock.withLock { recordedSubmissions }
    }

    var approvals: [(String, String)] {
        lock.withLock { recordedApprovals }
    }

    var cancelCount: Int {
        lock.withLock { cancels }
    }

    var quitCount: Int {
        lock.withLock { quits }
    }

    func makeHost(response: ChatStreamResponse? = nil) -> ClosureTUIAppHost {
        ClosureTUIAppHost(
            submit: { [self] submission in
                lock.withLock { recordedSubmissions.append(submission) }
                return response
            },
            cancelTurn: { [self] in
                lock.withLock { cancels += 1 }
            },
            quit: { [self] in
                lock.withLock { quits += 1 }
            },
            resolveApproval: { [self] approvalID, actionID in
                lock.withLock { recordedApprovals.append((approvalID, actionID)) }
            }
        )
    }
}
