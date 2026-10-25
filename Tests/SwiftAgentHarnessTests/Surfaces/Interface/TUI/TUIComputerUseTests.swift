import Foundation
import Testing
@testable import SwiftAgentHarness

private actor ComputerUseHostRecorder {
    private(set) var resolutions: [(String, ComputerUseRequestResolution)] = []
    private(set) var takeovers: [Bool] = []
    private(set) var stops = 0
    private(set) var approvals: [(String, String)] = []

    func resolve(_ id: String, _ resolution: ComputerUseRequestResolution) { resolutions.append((id, resolution)) }
    func takeover(_ on: Bool) { takeovers.append(on) }
    func stop() { stops += 1 }
    func approve(_ id: String, _ action: String) { approvals.append((id, action)) }
}

@Suite("TUI computer-use oversight")
struct TUIComputerUseTests {
    private func makeApp() async -> (TUIApp, ComputerUseHostRecorder) {
        let recorder = ComputerUseHostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 100, rows: 30))
        await app.setHost(ClosureTUIAppHost(
            submit: { _ in nil },
            resolveApproval: { await recorder.approve($0, $1) },
            resolveComputerUseRequest: { await recorder.resolve($0, $1) },
            stopComputerUse: { await recorder.stop() },
            setComputerUseTakeover: { await recorder.takeover($0) }
        ))
        return (app, recorder)
    }

    private func activity(_ status: ComputerUseSurfaceIntentPayload.Status, step: Int = 3) -> ChatStreamingPartial {
        .surfaceIntent(.computerUseActivity(ComputerUseSurfaceIntentPayload(
            target: "This Mac", lifecycleID: "call-1", status: status, step: step, maxSteps: 40, app: "com.apple.TextEdit", action: "click"
        )))
    }

    private func question(_ id: String = "cu-q-1", _ prompt: String = "Which file should I export?") -> ChatStreamingPartial {
        .surfaceIntent(.computerUseRequest(ComputerUseSurfaceIntentPayload(
            requestID: id, requestKind: .question, prompt: prompt, target: "This Mac", lifecycleID: "call-1"
        )))
    }

    private func handoff() -> ChatStreamingPartial {
        .surfaceIntent(.computerUseRequest(ComputerUseSurfaceIntentPayload(
            requestID: "cu-h-1", requestKind: .handoff, prompt: "Sign in to the portal", reason: "login", target: "This Mac", lifecycleID: "call-1"
        )))
    }

    private func frame(_ app: TUIApp) async -> String {
        await app.renderFrameLines(width: 100).joined(separator: "\n")
    }

    @Test("Activity shows the indicator with step and app, and ending the session clears it")
    func indicator() async {
        let (app, _) = await makeApp()
        await app.ingest(activity(.acting))
        var rendered = await frame(app)
        #expect(rendered.contains("Computer use on This Mac"))
        #expect(rendered.contains("step 3/40"))
        #expect(rendered.contains("^X stop"))

        await app.ingest(activity(.takenOver))
        rendered = await frame(app)
        #expect(rendered.contains("You have control of This Mac"))

        await app.ingest(activity(.ended))
        #expect(await !frame(app).contains("This Mac"))
    }

    @Test("Finishing the turn clears an indicator whose end event was missed")
    func finishClears() async {
        let (app, _) = await makeApp()
        await app.ingest(activity(.acting))
        await app.finishTurn()
        #expect(await !frame(app).contains("Computer use on"))
    }

    @Test("A question is answered from the dialog's text field")
    func answerQuestion() async {
        let (app, recorder) = await makeApp()
        await app.ingest(question())
        #expect(await frame(app).contains("Which file should I export?"))
        await app.handleKey(.enter)
        #expect(await recorder.resolutions.isEmpty, "an empty answer is not sent")
        await app.handleKey(.text("report.pdf"))
        await app.handleKey(.backspace)
        await app.handleKey(.text("f"))
        await app.handleKey(.enter)
        let resolutions = await recorder.resolutions
        #expect(resolutions.map(\.0) == ["cu-q-1"])
        #expect(resolutions.map(\.1) == [.answered("report.pdf")])
        #expect(await !app.hasOverlay())
    }

    @Test("Esc declines a question")
    func declineQuestion() async {
        let (app, recorder) = await makeApp()
        await app.ingest(question())
        await app.handleKey(.escape)
        #expect(await recorder.resolutions.map(\.1) == [.declined])
        #expect(await !app.hasOverlay())
    }

    @Test("A handoff hands back control from its default button, or declines")
    func handoffDialog() async {
        let (app, recorder) = await makeApp()
        await app.ingest(handoff())
        let rendered = await frame(app)
        #expect(rendered.contains("Sign in to the portal"))
        #expect(rendered.contains("Hand back control"))
        await app.handleKey(.enter)
        #expect(await recorder.resolutions.map(\.1) == [.handedBack(note: nil)])

        await app.ingest(handoff())
        await app.handleKey(.right)
        await app.handleKey(.enter)
        #expect(await recorder.resolutions.map(\.1) == [.handedBack(note: nil), .declined])
    }

    @Test("A request cleared elsewhere closes its dialog without resolving it")
    func clearedElsewhere() async {
        let (app, recorder) = await makeApp()
        await app.ingest(question())
        await app.ingest(.surfaceIntent(.computerUseRequestCleared(requestID: "cu-q-other", lifecycleID: "call-1")))
        #expect(await app.hasOverlay())
        await app.ingest(.surfaceIntent(.computerUseRequestCleared(requestID: "cu-q-1", lifecycleID: "call-1")))
        #expect(await !app.hasOverlay())
        #expect(await recorder.resolutions.isEmpty)
    }

    @Test("A request arriving behind an approval waits for it, and one cleared meanwhile is dropped")
    func queuedBehindApproval() async {
        let (app, recorder) = await makeApp()
        await app.ingest(.surfaceIntent(ClientSurfaceIntent(
            kind: .execApprovalRequired, approvalID: "a1", presentation: .standard(title: "Approve?")
        )))
        await app.ingest(question("cu-q-1", "First?"))
        await app.ingest(question("cu-q-2", "Second?"))
        await app.ingest(.surfaceIntent(.computerUseRequestCleared(requestID: "cu-q-1", lifecycleID: "call-1")))
        #expect(await frame(app).contains("Approve?"))

        await app.handleKey(.enter)
        #expect(await recorder.approvals.map(\.0) == ["a1"])
        let rendered = await frame(app)
        #expect(rendered.contains("Second?"))
        #expect(!rendered.contains("First?"))
    }

    @Test("Ctrl-T toggles takeover and Ctrl-X stops, only while computer use is active, even over a dialog")
    func shortcuts() async {
        let (app, recorder) = await makeApp()
        await app.handleRawInput(ComputerUseShortcut.toggleTakeover)
        await app.handleRawInput(ComputerUseShortcut.stop)
        #expect(await recorder.takeovers.isEmpty)
        #expect(await recorder.stops == 0)

        await app.ingest(activity(.acting))
        await app.handleRawInput(ComputerUseShortcut.toggleTakeover)
        await app.ingest(activity(.takenOver))
        await app.handleRawInput(ComputerUseShortcut.toggleTakeover)
        #expect(await recorder.takeovers == [true, false])

        await app.ingest(handoff())
        await app.handleRawInput(ComputerUseShortcut.stop)
        #expect(await recorder.stops == 1)
        #expect(await app.hasOverlay(), "stopping declines the request through the runtime, which clears it")
    }

    @Test("Approval cards show an image block as its placeholder")
    func approvalImagePlaceholder() async {
        let (app, _) = await makeApp()
        let image = PresentationImage(data: Data([1, 2, 3]), mediaType: "image/png", width: 240, height: 140, alt: "Target region: AXButton \"Send\"")
        await app.ingest(.surfaceIntent(ClientSurfaceIntent(
            kind: .execApprovalRequired,
            approvalID: "a1",
            presentation: ApprovalPresentation(blocks: [.text("Confirm send?"), .image(image), .buttons(ApprovalButton.standardDecisionButtons())])
        )))
        #expect(await frame(app).contains("[Target region: AXButton \"Send\" 240×140]"))
    }
}
