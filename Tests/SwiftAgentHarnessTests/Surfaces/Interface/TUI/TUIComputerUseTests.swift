import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

private actor ComputerUseHostRecorder {
    private(set) var resolutions: [(String, ComputerUseRequestResolution)] = []
    private(set) var takeovers: [Bool] = []
    private(set) var stops = 0
    private(set) var approvals: [(String, String)] = []
    private(set) var liveViews: [String] = []
    private(set) var liveViewRoles: [DisplayLiveViewRole] = []
    private(set) var observerEnds: [String] = []
    var endsObservers = true

    func resolve(_ id: String, _ resolution: ComputerUseRequestResolution) { resolutions.append((id, resolution)) }
    func takeover(_ on: Bool) { takeovers.append(on) }
    func stop() { stops += 1 }
    func approve(_ id: String, _ action: String) { approvals.append((id, action)) }
    func liveView(_ lifecycleID: String, _ role: DisplayLiveViewRole) -> DisplayLiveView {
        liveViews.append(lifecycleID)
        liveViewRoles.append(role)
        let prefix = role == .observer ? "observer-" : ""
        return DisplayLiveView(
            url: "http://127.0.0.1:4100/view#\(prefix)token-\(liveViews.count)", viewOnly: true, expiresAt: Date().addingTimeInterval(600), role: role
        )
    }
    func endObservers(_ lifecycleID: String) -> Bool {
        observerEnds.append(lifecycleID)
        return endsObservers
    }
    func setEndsObservers(_ value: Bool) { endsObservers = value }
}

@Suite("TUI computer-use oversight")
struct TUIComputerUseTests {
    private func makeApp() async -> (TUIApp, ComputerUseHostRecorder) {
        let recorder = ComputerUseHostRecorder()
        let app = TUIApp(terminal: VirtualTerminal(columns: 120, rows: 30))
        await app.setHost(ClosureTUIAppHost(
            submit: { _ in nil },
            resolveApproval: { await recorder.approve($0, $1) },
            resolveComputerUseRequest: { await recorder.resolve($0, $1) },
            stopComputerUse: { await recorder.stop() },
            setComputerUseTakeover: { await recorder.takeover($0) },
            computerUseLiveView: { await recorder.liveView($0, $1) },
            endComputerUseObservers: { await recorder.endObservers($0) }
        ))
        return (app, recorder)
    }

    private func activity(_ status: ComputerUseSurfaceIntentPayload.Status, step: Int = 3, liveView: Bool? = nil) -> ChatStreamingPartial {
        .surfaceIntent(.computerUseActivity(ComputerUseSurfaceIntentPayload(
            target: "This Mac", lifecycleID: "call-1", status: status, step: step, maxSteps: 40, app: "com.apple.TextEdit", action: "click",
            liveView: liveView
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
        await app.renderFrameLines(width: 120).joined(separator: "\n")
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

    @Test("Ctrl-O shows a clickable live view link, only for sessions that offer one")
    func liveViewShortcut() async {
        let (app, recorder) = await makeApp()
        await app.ingest(activity(.acting))
        #expect(await !frame(app).contains("^O live view"))
        await app.handleRawInput(ComputerUseShortcut.liveView)
        #expect(await recorder.liveViews.isEmpty)

        await app.ingest(activity(.acting, liveView: true))
        #expect(await frame(app).contains("^O live view"))
        await app.handleRawInput(ComputerUseShortcut.liveView)
        #expect(await recorder.liveViews == ["call-1"])
        let rendered = await frame(app)
        #expect(rendered.contains(TUIEscapes.hyperlink("http://127.0.0.1:4100/view#token-1", label: "http://127.0.0.1:4100/view#token-1")))
        #expect(rendered.contains("Live view"))
        #expect(!rendered.contains("^O live view"), "the hint gives way to the link")

        await app.handleRawInput(ComputerUseShortcut.liveView)
        #expect(await recorder.liveViews == ["call-1", "call-1"], "Ctrl-O always mints a fresh link")
        #expect(await frame(app).contains("token-2"))

        await app.ingest(activity(.ended))
        #expect(await !frame(app).contains("token-2"))
        #expect(await recorder.liveViewRoles == [.user, .user])
    }

    @Test("Ctrl-G shares a view-only link and pressing it again stops sharing, only for sessions that offer a live view")
    func shareShortcut() async {
        let (app, recorder) = await makeApp()
        await app.handleRawInput(ComputerUseShortcut.share)
        await app.ingest(activity(.acting))
        #expect(await !frame(app).contains("^G share"))
        await app.handleRawInput(ComputerUseShortcut.share)
        #expect(await recorder.liveViews.isEmpty)

        await app.ingest(activity(.acting, liveView: true))
        #expect(await frame(app).contains("^G share"))
        await app.handleRawInput(ComputerUseShortcut.share)
        #expect(await recorder.liveViewRoles == [.observer])
        var rendered = await frame(app)
        let url = "http://127.0.0.1:4100/view#observer-token-1"
        #expect(rendered.contains(TUIEscapes.hyperlink(url, label: url)))
        #expect(rendered.contains("Shared, view only"))
        #expect(rendered.contains("^G stop sharing"))
        #expect(rendered.contains("^O live view"), "sharing doesn't show the user's own link")

        await app.handleRawInput(ComputerUseShortcut.share)
        #expect(await recorder.observerEnds == ["call-1"])
        #expect(await recorder.liveViews.count == 1, "stopping doesn't mint another link")
        rendered = await frame(app)
        #expect(!rendered.contains("observer-token-1"))
        #expect(rendered.contains("^G share"))
    }

    @Test("Sharing works over a dialog, and stopping keeps the user's own link")
    func shareOverDialog() async {
        let (app, recorder) = await makeApp()
        await app.ingest(activity(.takenOver, liveView: true))
        await app.ingest(handoff())
        await app.handleRawInput(ComputerUseShortcut.share)
        #expect(await frame(app).contains("observer-token-2"))
        await app.handleRawInput(ComputerUseShortcut.share)
        #expect(await recorder.observerEnds == ["call-1"])
        let rendered = await frame(app)
        #expect(rendered.contains("view#token-1"))
        #expect(!rendered.contains("observer-token-2"))
        #expect(await app.hasOverlay())
    }

    @Test("A share that couldn't be stopped stays shown")
    func failedStopSharing() async {
        let (app, recorder) = await makeApp()
        await recorder.setEndsObservers(false)
        await app.ingest(activity(.acting, liveView: true))
        await app.handleRawInput(ComputerUseShortcut.share)
        await app.handleRawInput(ComputerUseShortcut.share)
        #expect(await recorder.observerEnds == ["call-1"])
        #expect(await frame(app).contains("^G stop sharing"))
    }

    @Test("A shared run whose link has expired still says it's shared, and ending the run clears it")
    func expiredShare() {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let indicator = ComputerUseIndicatorComponent(now: { clock.withLock { $0 } })
        let running = ComputerUseSurfaceIntentPayload(target: "Managed browser", lifecycleID: "call-1", status: .acting, liveView: true)
        indicator.apply(running)
        indicator.setObserverLink(
            DisplayLiveView(url: "http://127.0.0.1:4100/view#obs", viewOnly: true, expiresAt: Date(timeIntervalSince1970: 1_600), role: .observer),
            for: "call-1"
        )
        #expect(indicator.isSharing)
        #expect(indicator.render(width: 120).joined().contains("view#obs"))
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_601) }
        var rendered = indicator.render(width: 120).joined()
        #expect(!rendered.contains("view#obs"))
        #expect(rendered.contains("new viewers can't join"))
        #expect(rendered.contains("^G stop sharing"))
        #expect(indicator.observerLink(for: "call-1") == nil)

        indicator.apply(ComputerUseSurfaceIntentPayload(target: "Managed browser", lifecycleID: "call-1", status: .ended))
        indicator.apply(running)
        rendered = indicator.render(width: 120).joined()
        #expect(!indicator.isSharing)
        #expect(!rendered.contains("new viewers can't join"))
    }

    @Test("An unsafe share link is never shown")
    func unsafeShareLink() {
        let indicator = ComputerUseIndicatorComponent()
        indicator.apply(ComputerUseSurfaceIntentPayload(target: "Managed browser", lifecycleID: "call-1", status: .acting, liveView: true))
        indicator.setObserverLink(
            DisplayLiveView(url: "javascript:alert(1)", viewOnly: true, expiresAt: Date().addingTimeInterval(600), role: .observer), for: "call-1"
        )
        #expect(!indicator.isSharing)
    }

    @Test("Taking over shows a live view link without asking, once")
    func liveViewOnTakeover() async {
        let (app, recorder) = await makeApp()
        await app.ingest(activity(.takenOver))
        #expect(await recorder.liveViews.isEmpty, "no link for a target without a live view")

        await app.ingest(activity(.acting, liveView: true))
        #expect(await recorder.liveViews.isEmpty, "watching is opt-in while the agent acts")
        await app.ingest(activity(.takenOver, liveView: true))
        await app.ingest(activity(.takenOver, liveView: true))
        #expect(await recorder.liveViews == ["call-1"])
        #expect(await frame(app).contains("token-1"))
    }

    @Test("A handoff on a target with a live view points the user to its link")
    func handoffPointsToLiveView() async {
        let (app, _) = await makeApp()
        await app.ingest(activity(.takenOver, liveView: true))
        await app.ingest(handoff())
        let rendered = await frame(app)
        #expect(rendered.contains("through the live view"))
        #expect(rendered.contains("token-1"), "the link stays visible under the dialog")
    }

    @Test("The indicator drops a link once it can no longer connect")
    func expiredLink() {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let indicator = ComputerUseIndicatorComponent(now: { clock.withLock { $0 } })
        indicator.apply(ComputerUseSurfaceIntentPayload(target: "Managed browser", lifecycleID: "call-1", status: .acting, liveView: true))
        indicator.setLiveView(
            DisplayLiveView(url: "http://127.0.0.1:4100/view#abc", viewOnly: true, expiresAt: Date(timeIntervalSince1970: 1_600)),
            for: "call-1"
        )
        #expect(indicator.render(width: 100).joined().contains("view#abc"))
        #expect(indicator.liveView(for: "call-1") != nil)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_601) }
        let rendered = indicator.render(width: 100).joined()
        #expect(!rendered.contains("view#abc"))
        #expect(rendered.contains("^O live view"))
        #expect(indicator.liveView(for: "call-1") == nil)
    }

    @Test("A link that could break out of its escape sequence is never shown")
    func unsafeLink() {
        let indicator = ComputerUseIndicatorComponent()
        indicator.apply(ComputerUseSurfaceIntentPayload(target: "Managed browser", lifecycleID: "call-1", status: .acting, liveView: true))
        let later = Date().addingTimeInterval(600)
        for url in ["http://127.0.0.1/view#a\u{1B}]8;;x\u{07}", "javascript:alert(1)", "http://127.0.0.1/view#a b"] {
            indicator.setLiveView(DisplayLiveView(url: url, viewOnly: true, expiresAt: later), for: "call-1")
            #expect(indicator.liveView(for: "call-1") == nil, "\(url)")
        }
        indicator.setLiveView(DisplayLiveView(url: "https://agent.example.com/live/view#abc", viewOnly: true, expiresAt: later), for: "call-2")
        #expect(indicator.liveView(for: "call-2") == nil, "no such run")
    }

    @Test("The in-process host mints user and observer links from the run's target and ends its observers")
    func runtimeHostSharing() async throws {
        let parent = UUID()
        let installation = ComputerUseFixtures.installation(publisher: RecordingIntentPublisher())
        let (_, target) = try await ComputerUseFixtures.registerLiveSession(in: installation, parent: parent, lifecycleID: "call-1")
        await target.setLiveViewLink(DisplayLiveView(url: "http://127.0.0.1:9/view#t", viewOnly: true, expiresAt: ComputerUseFixtures.epoch))
        let host = RuntimeTUIHost(
            session: try MinimalAgentRuntimeSession.make(),
            conversationID: parent,
            computerUse: ComputerUseControlService(installation: installation)
        )

        #expect(await host.computerUseLiveView(lifecycleID: "call-1", role: .user)?.role == .user)
        #expect(await host.computerUseLiveView(lifecycleID: "call-1", role: .observer)?.role == .observer)
        #expect(await target.liveViewRoles == [.user, .observer])
        #expect(await host.endComputerUseObservers(lifecycleID: "call-1"))
        #expect(await target.observerEnds == 1)
        #expect(await !host.endComputerUseObservers(lifecycleID: "call-missing"))
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
