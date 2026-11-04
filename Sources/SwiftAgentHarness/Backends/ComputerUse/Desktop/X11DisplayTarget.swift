import Foundation

public struct X11DesktopConfiguration: Sendable {
    public var id: DisplayTargetID
    public var label: String
    public var isolation: DisplayTargetIsolation
    public var humanPresence: DisplayHumanPresence
    /// How long an action waits for the desktop to react before it returns.
    public var settleDelay: Duration
    /// How often the live view's picture is refreshed while someone watches.
    public var liveViewFrameInterval: Duration
    public var retainedObservations: Int

    public init(
        id: DisplayTargetID,
        label: String,
        isolation: DisplayTargetIsolation,
        humanPresence: DisplayHumanPresence = .exclusive,
        settleDelay: Duration = .milliseconds(150),
        liveViewFrameInterval: Duration = .milliseconds(500),
        retainedObservations: Int = 8
    ) {
        self.id = id
        self.label = label
        self.isolation = isolation
        self.humanPresence = humanPresence
        self.settleDelay = settleDelay
        self.liveViewFrameInterval = liveViewFrameInterval
        self.retainedObservations = max(1, retainedObservations)
    }
}

/// One X display the target drives for the length of a lease.
public struct X11DesktopSession: Sendable {
    /// Runs the driver's tools (`xdotool`, ImageMagick's `import`, `xprop`) where the display is.
    public var runner: any DisplayCommandRunner
    public var shutdown: @Sendable () async -> Void

    public init(runner: any DisplayCommandRunner, shutdown: @escaping @Sendable () async -> Void = {}) {
        self.runner = runner
        self.shutdown = shutdown
    }
}

/// A Linux desktop on an X display, driven from inside it with `xdotool` and ImageMagick: a desktop container, or a
/// Linux VM over SSH. Perception is pixels only, since no accessibility tree is read; delivery is background, since
/// the display is the target's own. Pointer actions cite a screenshot and are refused when the active window
/// changed since it.
///
/// With a live view server, each lease gets a feed: the screen is captured while someone watches, and a viewer's
/// input reaches it only during takeover.
public actor X11DisplayTarget: DisplayTarget {
    public nonisolated let manifest: DisplayTargetManifest
    public nonisolated let configuration: X11DesktopConfiguration
    private let provisioner: @Sendable () async throws -> X11DesktopSession
    private let liveViewServer: DisplayLiveViewServer?
    private let lock = DisplayTargetLeaseLock()
    private var session: X11DesktopSession?
    private var screen = ImagePixelSize(width: 0, height: 0)
    private var takeoverActive = false
    private var observationCounter = 0
    private var observedWindows: [ObservationID: String] = [:]
    private var observationOrder: [ObservationID] = []
    private var liveFeed: UUID?
    private var frames: Task<Void, Never>?

    struct WindowState: Equatable {
        var window: String
        var app: AppIdentity?
        var pid: Int32?
        var processStart: Date?
    }

    public init(
        configuration: X11DesktopConfiguration,
        liveView: DisplayLiveViewServer? = nil,
        provisioner: @escaping @Sendable () async throws -> X11DesktopSession
    ) {
        self.configuration = configuration
        self.provisioner = provisioner
        liveViewServer = liveView
        manifest = Self.manifest(for: configuration, servesLiveView: liveView != nil)
    }

    static func manifest(for configuration: X11DesktopConfiguration, servesLiveView: Bool) -> DisplayTargetManifest {
        DisplayTargetManifest(
            id: configuration.id,
            label: configuration.label,
            platform: "linux",
            isolation: configuration.isolation,
            perception: [.pixels],
            delivery: [.background],
            semanticActions: [.launchApp, .openURL],
            observerAccess: servesLiveView ? .stream : .none,
            humanPresence: configuration.humanPresence
        )
    }

    // MARK: - Lifecycle

    public func lease(_ request: LeaseRequest) async throws -> Lease {
        let lease = Lease(request: request, issuedAt: Date())
        try await lock.acquire(leaseID: lease.id, holder: DisplayTargetLeaseLock.Holder(id: request.agentID, isAlive: request.isHolderAlive))
        let session: X11DesktopSession
        do {
            session = try await provisioner()
        } catch {
            await lock.release(leaseID: lease.id)
            throw DisplayTargetError.driverFailure("the desktop did not start: \(error)")
        }
        do {
            let geometry = try await session.runner.output(["xdotool", "getdisplaygeometry"]).text.split(whereSeparator: \.isWhitespace)
            guard geometry.count == 2, let width = Int(geometry[0]), let height = Int(geometry[1]), width > 0, height > 0 else {
                throw DisplayTargetError.driverFailure("the display reported no size")
            }
            screen = ImagePixelSize(width: width, height: height)
        } catch {
            await session.shutdown()
            await lock.release(leaseID: lease.id)
            throw DisplayTargetError.driverFailure("the desktop's display is unreachable: \(error)")
        }
        self.session = session
        takeoverActive = false
        observationCounter = 0
        observedWindows = [:]
        observationOrder = []
        if let liveViewServer {
            liveFeed = await liveViewServer.open(DisplayLiveViewFeed(
                label: configuration.label,
                viewersChanged: { [weak self] count in await self?.viewersChanged(count) },
                input: { [weak self] input in await self?.liveInput(input) }
            ))
        }
        return lease
    }

    public func release(_ lease: Lease, reason: ReleaseReason) async {
        guard await lock.holds(leaseID: lease.id) else { return }
        frames?.cancel()
        frames = nil
        if let session {
            _ = try? await session.runner.run(["xdotool", "keyup", "shift", "ctrl", "alt", "super"])
            await session.shutdown()
        }
        session = nil
        takeoverActive = false
        if let liveFeed { await liveViewServer?.close(liveFeed) }
        liveFeed = nil
        await lock.release(leaseID: lease.id)
    }

    public func permissions() async -> PermissionSnapshot {
        PermissionSnapshot(states: [:])
    }

    public func describe(_ lease: Lease) async throws -> TargetLayout {
        try await requireLease(lease)
        let window = try await activeWindow()
        return TargetLayout(
            displays: [DisplayInfo(id: "screen", frame: screenRect, scaleFactor: 1, isPrimary: true)],
            focusedApp: window.app
        )
    }

    public func takeover(_ lease: Lease, on: Bool) async throws {
        try await requireLease(lease)
        takeoverActive = on
        if let liveFeed { await liveViewServer?.setControl(on, for: liveFeed) }
    }

    public func liveView(_ lease: Lease, role: DisplayLiveViewRole) async throws -> DisplayLiveView? {
        try await requireLease(lease)
        guard let liveViewServer, let liveFeed else { return nil }
        return try await liveViewServer.link(for: liveFeed, role: role)
    }

    public func endObservers(_ lease: Lease) async throws {
        try await requireLease(lease)
        if let liveFeed { await liveViewServer?.endObservers(liveFeed) }
    }

    public func liveViewers(_ lease: Lease) async throws -> Int {
        try await requireLease(lease)
        guard let liveViewServer, let liveFeed else { return 0 }
        return await liveViewServer.viewerCount(liveFeed)
    }

    // MARK: - Perception

    private var screenRect: DisplayRect {
        DisplayRect(x: 0, y: 0, width: Double(screen.width), height: Double(screen.height))
    }

    public func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        try await requireLease(lease)
        guard !takeoverActive else { throw DisplayTargetError.unsupported("the user has taken over; capture is paused") }
        observationCounter += 1
        let id: ObservationID = "o_\(observationCounter)"
        let window = try await activeWindow()
        var image: ObservationImage?
        if request.modes.contains(.pixels) {
            let screen = screenRect
            var captured = screen
            if case .region(let region) = request.scope {
                captured = DisplayRect(
                    x: max(screen.minX, region.minX).rounded(.down),
                    y: max(screen.minY, region.minY).rounded(.down),
                    width: (min(screen.maxX, region.maxX) - max(screen.minX, region.minX)).rounded(.up),
                    height: (min(screen.maxY, region.maxY) - max(screen.minY, region.minY)).rounded(.up)
                )
                guard captured.width >= 1, captured.height >= 1 else { throw DisplayTargetError.unsupported("the region lies outside the screen") }
            }
            let isZoom = if case .region = request.scope { true } else { false }
            let scale = ManagedBrowserDisplayTarget.scale(for: captured, limit: request.maxImage, zoom: isZoom)
            let size = ImagePixelSize(
                width: max(1, Int((captured.width * scale).rounded())),
                height: max(1, Int((captured.height * scale).rounded()))
            )
            var argv = ["import", "-silent", "-window", "root"]
            if captured != screen {
                argv += ["-crop", "\(Int(captured.width))x\(Int(captured.height))+\(Int(captured.x))+\(Int(captured.y))", "+repage"]
            }
            argv += ["-resize", "\(size.width)x\(size.height)!", "png:-"]
            let data = try await runner().output(argv).stdout
            guard !data.isEmpty else { throw DisplayTargetError.driverFailure("the screenshot was empty") }
            image = ObservationImage(
                blobRef: "x11:\(id)",
                data: data,
                mediaType: "image/png",
                geometry: ScreenshotGeometry(capturedRect: captured, imageSize: ManagedBrowserDisplayTarget.pngSize(data) ?? size, scaleFactor: 1),
                capturedAt: Date()
            )
        }
        observedWindows[id] = window.window
        observationOrder.append(id)
        while observationOrder.count > configuration.retainedObservations {
            observedWindows[observationOrder.removeFirst()] = nil
        }
        return DisplayObservation(
            id: id,
            at: Date(),
            target: ObservationTarget(
                app: window.app,
                pid: window.pid,
                processStart: window.processStart,
                windowID: window.window.isEmpty ? nil : window.window,
                bounds: screenRect
            ),
            image: image
        )
    }

    /// The focused window and its owner. Its title isn't read: screen text never decides identity.
    func activeWindow() async throws -> WindowState {
        let script = """
        w=$(xdotool getactivewindow 2>/dev/null) || w=""
        echo "window=$w"
        [ -n "$w" ] || exit 0
        p=$(xdotool getwindowpid "$w" 2>/dev/null)
        echo "pid=$p"
        echo "class=$(xprop -id "$w" WM_CLASS 2>/dev/null | sed -n 's/.*, "\\(.*\\)"$/\\1/p')"
        [ -n "$p" ] || exit 0
        ticks=$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null | cut -d' ' -f20)
        boot=$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null)
        hz=$(getconf CLK_TCK 2>/dev/null)
        [ -n "$ticks" ] && [ -n "$boot" ] && [ -n "$hz" ] && echo "start=$((boot + ticks / hz))"
        exit 0
        """
        let text = try await runner().output(["sh", "-c", script]).text
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<equals])] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        let pid = fields["pid"].flatMap { Int32($0) }
        let start = fields["start"].flatMap { TimeInterval($0) }
        return WindowState(
            window: fields["window"] ?? "",
            app: fields["class"].flatMap { $0.isEmpty ? nil : AppIdentity(bundleID: $0) },
            pid: pid,
            processStart: start.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - Action

    public func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        try await requireLease(lease)
        guard !takeoverActive else { throw DisplayTargetError.unsupported("the user has taken over; agent input is paused") }
        var outcomes: [ActionOutcome] = []
        for (index, action) in batch.actions.enumerated() {
            var outcome = await perform(action)
            outcome.action = index
            outcomes.append(outcome)
            if outcome.effect.stopsBatch { break }
        }
        return outcomes
    }

    private struct Refusal: Error {
        var outcome: ActionOutcome
    }

    private func refused(_ message: String, escalation: ActionEscalation? = nil) -> ActionOutcome {
        ActionOutcome(action: 0, effect: .refused, evidence: message, escalation: escalation)
    }

    private func perform(_ action: ComputerAction) async -> ActionOutcome {
        do {
            switch action {
            case .click(let at, let button, let count, let modifiers):
                let point = try await resolve(at)
                try await xdotool(["mousemove", "--sync", Self.coordinate(point.x), Self.coordinate(point.y)])
                try await holding(modifiers) {
                    try await self.xdotool(["click", "--repeat", String(max(1, min(count, 3))), "--delay", "80", Self.buttonNumber(button)])
                }
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "clicked at (\(Int(point.x)), \(Int(point.y)))")
            case .move(let to):
                let point = try await resolve(to)
                try await xdotool(["mousemove", "--sync", Self.coordinate(point.x), Self.coordinate(point.y)])
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "pointer moved")
            case .drag(let path, let modifiers):
                guard path.count >= 2 else { return refused("a drag needs at least two points") }
                var points: [DisplayPoint] = []
                for target in path { points.append(try await resolve(target)) }
                try await xdotool(["mousemove", "--sync", Self.coordinate(points[0].x), Self.coordinate(points[0].y)])
                try await holding(modifiers) {
                    try await self.xdotool(["mousedown", "1"])
                    do {
                        for (from, to) in zip(points, points.dropFirst()) {
                            for step in 1...8 {
                                let t = Double(step) / 8
                                try await self.xdotool(["mousemove", Self.coordinate(from.x + (to.x - from.x) * t), Self.coordinate(from.y + (to.y - from.y) * t)])
                            }
                        }
                    } catch {
                        _ = try? await self.xdotool(["mouseup", "1"])
                        throw error
                    }
                    try await self.xdotool(["mouseup", "1"])
                }
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "dragged through \(points.count) points")
            case .pointer(let state):
                try await xdotool([state == .down ? "mousedown" : "mouseup", "1"])
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "pointer \(state.rawValue)")
            case .scroll(let at, let dx, let dy, let unit):
                if let at {
                    let point = try await resolve(at)
                    try await xdotool(["mousemove", "--sync", Self.coordinate(point.x), Self.coordinate(point.y)])
                }
                let factor = unit == .pixel ? 1.0 / 40 : 1
                for (amount, positive, negative) in [(dy * factor, "5", "4"), (dx * factor, "7", "6")] {
                    let clicks = min(Int(abs(amount).rounded()), 50)
                    guard clicks > 0 else { continue }
                    try await xdotool(["click", "--repeat", String(clicks), "--delay", "20", amount > 0 ? positive : negative])
                }
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "scrolled")
            case .type(let text, let into, let mode):
                guard mode != .setValue else { return refused("set-value needs an element tree, which this desktop doesn't have") }
                if let into {
                    let point = try await resolve(into)
                    try await xdotool(["mousemove", "--sync", Self.coordinate(point.x), Self.coordinate(point.y)])
                    try await xdotool(["click", "1"])
                }
                try await runner().output(["xdotool", "type", "--clearmodifiers", "--delay", "12", "--file", "-"], stdin: Data(text.utf8), timeout: .seconds(120))
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "typed \(text.count) characters")
            case .key(let combo, let repeatCount):
                guard let chord = X11Keys.chord(combo) else { return refused("\(combo) names no key") }
                try await xdotool(["key", "--clearmodifiers", "--repeat", String(max(1, min(repeatCount, 100))), "--delay", "40", chord])
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "\(combo) sent")
            case .hold(let combo, let milliseconds):
                guard let chord = X11Keys.chord(combo) else { return refused("\(combo) names no key") }
                try await xdotool(["keydown", chord])
                try? await Task.sleep(for: .milliseconds(max(0, min(milliseconds, 10_000))))
                try await xdotool(["keyup", chord])
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "\(combo) held \(milliseconds) ms")
            case .press, .setValue, .menu:
                return refused("this desktop has no element tree; act on a point from a screenshot")
            case .launch(let app, _):
                guard app.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"#, options: .regularExpression) != nil else {
                    return refused("\(app) isn't a command name")
                }
                return try await detach(app, script: #"command -v "$0" >/dev/null || exit 127; setsid -f "$0" >/dev/null 2>&1 </dev/null"#, started: "started \(app)", missing: "\(app) isn't installed")
            case .openURL(let url):
                return try await detach(url, script: #"command -v xdg-open >/dev/null || exit 127; setsid -f xdg-open "$0" >/dev/null 2>&1 </dev/null"#, started: "asked the desktop to open the URL", missing: "the desktop has no xdg-open to open URLs with")
            case .wait(let milliseconds):
                try? await Task.sleep(for: .milliseconds(max(0, min(milliseconds, 60_000))))
                return ActionOutcome(action: 0, effect: .confirmed, evidence: "waited \(milliseconds) ms")
            case .waitFor:
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "the driver does not evaluate conditions; observe to check", escalation: .observe)
            case .observe, .zoom:
                return refused("observe through the session, not as a driver action")
            case .script:
                // A desktop script can reach any app, so it couldn't be held to per-app grants.
                return refused("this target runs no scripts")
            }
        } catch let refusal as Refusal {
            return refusal.outcome
        } catch {
            return ActionOutcome(action: 0, effect: .unverifiable, evidence: "driver error: \(error)", escalation: .observe)
        }
    }

    /// A point from a retained screenshot, refused when the focused window changed since: what was under it may
    /// have moved.
    private func resolve(_ target: ActionTarget) async throws -> DisplayPoint {
        guard case .point(let point, let observation) = target else {
            throw Refusal(outcome: refused("this desktop has no element tree; act on a point from a screenshot"))
        }
        guard let window = observedWindows[observation] else {
            throw Refusal(outcome: refused("observation \(observation) is not retained; observe again", escalation: .observe))
        }
        guard screenRect.contains(point) else { throw Refusal(outcome: refused("the point lies outside the screen")) }
        let current = try await activeWindow()
        guard current.window == window else {
            throw Refusal(outcome: refused("the active window changed since observation \(observation); observe again", escalation: .observe))
        }
        return point
    }

    private func detach(_ argument: String, script: String, started: String, missing: String) async throws -> ActionOutcome {
        let result = try await runner().run(["sh", "-c", script, argument])
        if result.exitCode == 127 { return refused(missing) }
        guard result.exitCode == 0 else {
            return ActionOutcome(action: 0, effect: .partial, evidence: "the command failed (\(result.exitCode))", escalation: .observe)
        }
        try await settle()
        return ActionOutcome(action: 0, effect: .unverifiable, evidence: started)
    }

    /// Runs `body` with `modifiers` held, releasing them however it ends.
    private func holding(_ modifiers: [KeyModifier], _ body: () async throws -> Void) async throws {
        let names = modifiers.compactMap { X11Keys.modifierNames[$0] }
        guard !names.isEmpty else { return try await body() }
        try await xdotool(["keydown"] + names)
        do {
            try await body()
        } catch {
            _ = try? await xdotool(["keyup"] + names)
            throw error
        }
        try await xdotool(["keyup"] + names)
    }

    private func settle() async throws {
        try? await Task.sleep(for: configuration.settleDelay)
    }

    private func xdotool(_ arguments: [String]) async throws {
        _ = try await runner().output(["xdotool"] + arguments)
    }

    private func runner() throws -> any DisplayCommandRunner {
        guard let session else { throw DisplayTargetError.leaseNotHeld }
        return session.runner
    }

    static func coordinate(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    static func buttonNumber(_ button: MouseButton) -> String {
        switch button {
        case .left: "1"
        case .middle: "2"
        case .right: "3"
        }
    }

    // MARK: - Live view

    private func viewersChanged(_ count: Int) {
        guard session != nil else { return }
        if count > 0, frames == nil {
            frames = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.publishFrame()
                    try? await Task.sleep(for: self.configuration.liveViewFrameInterval)
                }
            }
        } else if count == 0 {
            frames?.cancel()
            frames = nil
        }
    }

    private func publishFrame() async {
        guard let liveFeed, let liveViewServer, let jpeg = try? await runner().output(["import", "-silent", "-window", "root", "-quality", "60", "jpeg:-"]).stdout,
              !jpeg.isEmpty else { return }
        await liveViewServer.publish(DisplayLiveViewFrame(jpeg: jpeg, width: screen.width, height: screen.height), to: liveFeed)
    }

    /// A viewer's input, during takeover only. Frames are the screen at full size, so points need no mapping.
    private func liveInput(_ input: DisplayLiveViewInput) async {
        guard takeoverActive, session != nil else { return }
        func clamp(_ x: Double, _ y: Double) -> [String] {
            [Self.coordinate(min(max(x, 0), Double(screen.width - 1))), Self.coordinate(min(max(y, 0), Double(screen.height - 1)))]
        }
        switch input {
        case .mouse(let action, let x, let y, let button, _, _):
            _ = try? await xdotool(["mousemove"] + clamp(x, y))
            if let button, action != .move {
                _ = try? await xdotool([action == .down ? "mousedown" : "mouseup", Self.buttonNumber(button)])
            }
        case .wheel(let x, let y, let dx, let dy, _):
            _ = try? await xdotool(["mousemove"] + clamp(x, y))
            for (amount, positive, negative) in [(dy, "5", "4"), (dx, "7", "6")] where abs(amount) >= 1 {
                let clicks = max(1, min(Int((abs(amount) / 40).rounded()), 10))
                _ = try? await xdotool(["click", "--repeat", String(clicks), amount > 0 ? positive : negative])
            }
        case .key(let down, let key, _, _, let text, let modifiers):
            // A character is typed on its way down, which handles layout and shift; its release isn't sent.
            if key.count == 1, modifiers.isDisjoint(with: [.ctrl, .cmd]) {
                if down, let text { _ = try? await runner().output(["xdotool", "type", "--file", "-"], stdin: Data(text.utf8)) }
            } else if let keysym = X11Keys.domKeysym(key) ?? X11Keys.keysym(key.lowercased()) {
                _ = try? await xdotool([down ? "keydown" : "keyup", keysym])
            }
        case .text(let text):
            _ = try? await runner().output(["xdotool", "type", "--file", "-"], stdin: Data(text.utf8), timeout: .seconds(120))
        }
    }

    private func requireLease(_ lease: Lease) async throws {
        guard await lock.holds(leaseID: lease.id) else { throw DisplayTargetError.leaseNotHeld }
    }
}
