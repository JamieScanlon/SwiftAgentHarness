import EasyJSON
import Foundation

public struct ManagedBrowserConfiguration: Sendable {
    public var id: DisplayTargetID
    public var label: String
    /// The page viewport in CSS pixels: the target's whole coordinate space.
    public var viewport: ImagePixelSize
    /// Checked before every navigation and on the page's final URL. A launched browser also has every
    /// connection checked by its network proxy.
    public var network: BrowserNetworkPolicy
    /// How long an action waits for a navigation it started to finish loading.
    public var navigationTimeout: Duration
    /// How long an action waits for the page to react before its effect is read.
    public var settleDelay: Duration
    /// Most elements in one tree.
    public var maxElements: Int
    public var retainedObservations: Int
    /// Where each lease's downloads go, in a folder of their own. Defaults to the temporary directory.
    public var downloadsDirectory: URL?

    public init(
        id: DisplayTargetID = "managed-browser",
        label: String = "Managed browser",
        viewport: ImagePixelSize = ImagePixelSize(width: 1280, height: 800),
        network: BrowserNetworkPolicy = BrowserNetworkPolicy(),
        navigationTimeout: Duration = .seconds(15),
        settleDelay: Duration = .milliseconds(150),
        maxElements: Int = 600,
        retainedObservations: Int = 8,
        downloadsDirectory: URL? = nil
    ) {
        self.id = id
        self.label = label
        self.viewport = viewport
        self.network = network
        self.navigationTimeout = navigationTimeout
        self.settleDelay = settleDelay
        self.maxElements = max(1, maxElements)
        self.retainedObservations = max(1, retainedObservations)
        self.downloadsDirectory = downloadsDirectory
    }
}

/// Whose browser profile a lease works in.
public enum ManagedBrowserProfile: Sendable, Hashable {
    /// A fresh browser context per lease, thrown away on release. Downloads go to a lease folder.
    case throwaway
    /// The browser's own profile, with the user's sign-ins: the lease gets tabs of its own, the one it opens and
    /// the popups those open, closed on release. The agent never sees the user's other tabs. Its downloads go to a
    /// lease folder and are listed in the result.
    case user
}

/// One browser the target drives for the length of a lease.
public struct ManagedBrowserSession: Sendable {
    public var connection: any CDPSending
    /// Connections the browser's network refused since a date.
    public var networkDenials: @Sendable (Date) async -> [BrowserNetworkDenial]
    public var shutdown: @Sendable () async -> Void

    public init(
        connection: any CDPSending,
        networkDenials: @escaping @Sendable (Date) async -> [BrowserNetworkDenial] = { _ in [] },
        shutdown: @escaping @Sendable () async -> Void = {}
    ) {
        self.connection = connection
        self.networkDenials = networkDenials
        self.shutdown = shutdown
    }
}

/// A Chromium-family browser driven over the DevTools protocol, with no user data: each lease gets a fresh browser
/// context with downloads denied, and it is thrown away on release. Perception is the DOM and pixels; delivery is
/// always background, since CDP input reaches the page and never the browser's own UI or the host.
///
/// The coordinate space is the page viewport in CSS pixels. The browser has no app identity, so actions are
/// granted by the page's domain.
///
/// With a live view server, each lease gets a feed: the page is streamed while someone watches, and a viewer's
/// input reaches the page only during takeover.
public actor ManagedBrowserDisplayTarget: DisplayTarget {
    public nonisolated let manifest: DisplayTargetManifest
    private let eventHub = DisplayTargetEventHub()
    public nonisolated let configuration: ManagedBrowserConfiguration
    public nonisolated let profile: ManagedBrowserProfile
    private let launcher: @Sendable () async throws -> ManagedBrowserSession
    private let liveViewServer: DisplayLiveViewServer?
    private var liveFeed: UUID?
    private var casting = false
    private let lock = DisplayTargetLeaseLock()
    private var page: Page?
    private var takeoverActive = false
    private var observationCounter = 0
    private var observations: [ObservationID: ObservationMeta] = [:]
    private var observationOrder: [ObservationID] = []
    private var lastPointer: DisplayPoint?
    /// Things the page did on its own that the next observation reports, such as a new tab or a download.
    private var notices: [String] = []
    /// The lease's tabs besides the active `page`, oldest first.
    private var otherTabs: [Page] = []
    private var events: Task<Void, Never>?
    private var grants = ComputerUseGrantSet([])
    /// A JavaScript dialog the page is paused on, by tab session. The model answers it; it is never auto-accepted.
    private var dialogs: [String: Dialog] = [:]
    private var downloadsFolder: URL?
    private var downloadsByGUID: [String: Download] = [:]
    /// Downloads a tab of the lease's started; in the user's profile the others are the user's.
    private var agentDownloads: Set<String> = []

    struct Page {
        var session: ManagedBrowserSession
        var contextID: String
        var targetID: String
        var sessionID: String
        var frameID: String?
        var world: Int?
        var url: String?
    }

    struct Dialog {
        var type: String
        var message: String
        var promptText: String
    }

    struct Download {
        var name: String
        var completed: Bool
    }

    struct ObservationMeta {
        var doc: String?
        var scrollX: Double
        var scrollY: Double
        var elements: [String: ManagedBrowserPageSnapshot.Element]
        /// Taken while the page was paused on a dialog.
        var dialog = false
    }

    public init(
        configuration: ManagedBrowserConfiguration = ManagedBrowserConfiguration(),
        isolation: DisplayTargetIsolation,
        profile: ManagedBrowserProfile = .throwaway,
        liveView: DisplayLiveViewServer? = nil,
        launcher: @escaping @Sendable () async throws -> ManagedBrowserSession
    ) {
        self.configuration = configuration
        self.profile = profile
        self.launcher = launcher
        liveViewServer = liveView
        manifest = DisplayTargetManifest(
            id: configuration.id,
            label: configuration.label,
            platform: "chromium",
            isolation: isolation,
            perception: [.dom, .pixels],
            delivery: [.background],
            semanticActions: [.press, .setValue, .focus, .openURL],
            observerAccess: liveView == nil ? .none : .stream,
            scripting: [.javascript],
            humanPresence: profile == .user ? .shared : .exclusive
        )
    }

    /// A browser reached by its DevTools WebSocket URL, such as a hosted browser. Its network is the host's: the
    /// policy is applied to navigations and final URLs only.
    public static func hosted(
        endpoint: URL,
        configuration: ManagedBrowserConfiguration = ManagedBrowserConfiguration(),
        liveView: DisplayLiveViewServer? = nil
    ) -> ManagedBrowserDisplayTarget {
        ManagedBrowserDisplayTarget(configuration: configuration, isolation: .remoteBrowser, liveView: liveView) {
            let connection = CDPConnection(transport: CDPWebSocketTransport(url: endpoint))
            await connection.start()
            return ManagedBrowserSession(connection: connection, shutdown: { await connection.close() })
        }
    }

    /// The user's own Chrome, attached over remote debugging: their sign-ins, in a tab of the agent's own. It is a
    /// host target a person uses, so it needs a present operator, and scripts and other interact actions are
    /// confirmed unless an intent check passes them. Its network is the user's: the policy is applied to navigations
    /// and final URLs only.
    public static func userBrowser(
        endpoint: UserBrowserEndpoint = .chrome,
        configuration: ManagedBrowserConfiguration = ManagedBrowserConfiguration(id: "user-browser", label: "Your browser"),
        liveView: DisplayLiveViewServer? = nil
    ) -> ManagedBrowserDisplayTarget {
        ManagedBrowserDisplayTarget(configuration: configuration, isolation: .host, profile: .user, liveView: liveView) {
            let connection = CDPConnection(transport: CDPWebSocketTransport(url: try endpoint.resolve()))
            await connection.start()
            return ManagedBrowserSession(connection: connection, shutdown: { await connection.close() })
        }
    }

    #if os(macOS) || os(Linux)
    /// A Chromium the target launches for each lease, with a throwaway profile, reached over its debugging pipe, and
    /// whose only route to the network is a policy proxy.
    public static func localChromium(
        configuration: ManagedBrowserConfiguration = ManagedBrowserConfiguration(),
        chromium: ManagedChromiumConfiguration = ManagedChromiumConfiguration(),
        resolver: any BrowserNetworkResolving = SystemBrowserNetworkResolver(),
        liveView: DisplayLiveViewServer? = nil
    ) -> ManagedBrowserDisplayTarget {
        var chromium = chromium
        chromium.viewport = configuration.viewport
        let browserConfiguration = chromium
        return ManagedBrowserDisplayTarget(configuration: configuration, isolation: .process, liveView: liveView) {
            let proxy = BrowserNetworkProxy(policy: configuration.network, resolver: resolver)
            let port = try await proxy.start()
            let browser: ManagedChromium
            do {
                browser = try await ManagedChromium.launch(browserConfiguration, proxyPort: port)
            } catch {
                await proxy.stop()
                throw error
            }
            return ManagedBrowserSession(
                connection: browser.connection,
                networkDenials: { await proxy.denials(since: $0) },
                shutdown: {
                    await browser.shutdown()
                    await proxy.stop()
                }
            )
        }
    }
    #endif

    // MARK: - Lifecycle

    public func lease(_ request: LeaseRequest) async throws -> Lease {
        let lease = Lease(request: request, issuedAt: Date())
        try await lock.acquire(leaseID: lease.id, holder: DisplayTargetLeaseLock.Holder(id: request.agentID, isAlive: request.isHolderAlive))
        do {
            page = try await openPage()
        } catch {
            await lock.release(leaseID: lease.id)
            throw DisplayTargetError.driverFailure("the browser did not start: \(error)")
        }
        takeoverActive = false
        casting = false
        observations = [:]
        observationOrder = []
        notices = []
        lastPointer = nil
        grants = ComputerUseGrantSet(request.grants)
        dialogs = [:]
        downloadsByGUID = [:]
        agentDownloads = []
        await prepareDownloads(lease: lease)
        if let liveViewServer {
            liveFeed = await liveViewServer.open(DisplayLiveViewFeed(
                label: configuration.label,
                viewersChanged: { [weak self] count in await self?.viewersChanged(count) },
                input: { [weak self] input in await self?.liveInput(input) },
                typed: { [eventHub, leaseID = lease.id] value in eventHub.post(.typedDuringTakeover(value), to: leaseID) }
            ))
        }
        return lease
    }

    public func events(_ lease: Lease) async -> AsyncStream<DisplayTargetEvent> {
        guard await lock.holds(leaseID: lease.id) else { return AsyncStream { $0.finish() } }
        return eventHub.stream(for: lease.id)
    }

    public func release(_ lease: Lease, reason: ReleaseReason) async {
        guard await lock.holds(leaseID: lease.id) else { return }
        eventHub.finish(lease.id)
        if let page {
            events?.cancel()
            let connection = page.session.connection
            switch profile {
            case .throwaway:
                _ = try? await connection.send("Target.disposeBrowserContext", ["browserContextId": .string(page.contextID)])
            case .user:
                for tab in [page] + otherTabs {
                    _ = try? await connection.send("Target.closeTarget", ["targetId": .string(tab.targetID)])
                }
                // The user's own download setting comes back once the lease's tabs are gone.
                _ = try? await connection.send("Browser.setDownloadBehavior", ["behavior": .string("default")])
            }
            await page.session.shutdown()
        }
        events = nil
        page = nil
        otherTabs = []
        dialogs = [:]
        takeoverActive = false
        casting = false
        if let liveFeed { await liveViewServer?.close(liveFeed) }
        liveFeed = nil
        await lock.release(leaseID: lease.id)
    }

    public func permissions() async -> PermissionSnapshot {
        PermissionSnapshot(states: [:])
    }

    public func describe(_ lease: Lease) async throws -> TargetLayout {
        try await requireLease(lease)
        let page = try await self.page(of: lease)
        let state = try await pageState()
        return TargetLayout(
            displays: [DisplayInfo(id: "viewport", frame: viewportRect(state), scaleFactor: 1, isPrimary: true)],
            tabs: [TabInfo(id: page.targetID, url: state.url, isActive: true)]
                + otherTabs.map { TabInfo(id: $0.targetID, url: $0.url ?? "", isActive: false) }
        )
    }

    public func takeover(_ lease: Lease, on: Bool) async throws {
        try await requireLease(lease)
        takeoverActive = on
        if let liveFeed { await liveViewServer?.setControl(on, for: liveFeed) }
        if !on, let url = try? await pageState().url, let reason = configuration.network.evaluate(url: url).denialReason {
            _ = try? await send("Page.navigate", ["url": .string("about:blank")])
            notices.append("During the takeover the page went to \(url), which network policy blocks (\(reason)); it was cleared.")
        }
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

    public func liveConnections(_ lease: Lease) async throws -> [DisplayLiveViewConnection] {
        try await requireLease(lease)
        guard let liveViewServer, let liveFeed else { return [] }
        return await liveViewServer.connections(liveFeed)
    }

    public func revokeLiveView(_ lease: Lease, id: UUID) async throws -> Bool {
        try await requireLease(lease)
        guard let liveViewServer, let liveFeed else { return false }
        return await liveViewServer.revoke(id, in: liveFeed)
    }

    private func openPage() async throws -> Page {
        let session = try await launcher()
        do {
            let connection = session.connection
            let contextID: String
            let targetID: String
            switch profile {
            case .throwaway:
                let context = try await connection.send("Target.createBrowserContext", ["disposeOnDetach": .boolean(true)])
                guard let id = context[wire: "browserContextId"]?.wireString else { throw DisplayTargetError.driverFailure("no browser context") }
                contextID = id
                let created = try await connection.send("Target.createTarget", ["url": .string("about:blank"), "browserContextId": .string(contextID)])
                guard let id = created[wire: "targetId"]?.wireString else { throw DisplayTargetError.driverFailure("no page target") }
                targetID = id
            case .user:
                let created = try await connection.send("Target.createTarget", ["url": .string("about:blank"), "background": .boolean(true)])
                guard let id = created[wire: "targetId"]?.wireString else { throw DisplayTargetError.driverFailure("no page target") }
                targetID = id
                let info = try await connection.send("Target.getTargetInfo", ["targetId": .string(targetID)])
                contextID = info[wire: "targetInfo"]?[wire: "browserContextId"]?.wireString ?? ""
            }
            let stream = await connection.events()
            let page = try await attach(session: session, contextID: contextID, targetID: targetID)
            _ = try? await connection.send("Target.setDiscoverTargets", ["discover": .boolean(true)])
            events = Task { [weak self] in
                for await event in stream {
                    await self?.handle(event)
                }
            }
            return page
        } catch {
            await session.shutdown()
            throw error
        }
    }

    private func attach(session: ManagedBrowserSession, contextID: String, targetID: String) async throws -> Page {
        let connection = session.connection
        let attached = try await connection.send("Target.attachToTarget", ["targetId": .string(targetID), "flatten": .boolean(true)])
        guard let sessionID = attached[wire: "sessionId"]?.wireString else { throw DisplayTargetError.driverFailure("could not attach to the page") }
        _ = try await connection.send("Page.enable", session: sessionID)
        _ = try await connection.send("Emulation.setDeviceMetricsOverride", [
            "width": .integer(configuration.viewport.width),
            "height": .integer(configuration.viewport.height),
            "deviceScaleFactor": .integer(1),
            "mobile": .boolean(false),
        ], session: sessionID)
        return Page(session: session, contextID: contextID, targetID: targetID, sessionID: sessionID)
    }

    /// Downloads go to a folder of the lease's own, with events on so each file is tracked; nothing is opened. In
    /// the user's profile this is the browser-wide setting, restored on release, and downloads from the user's own
    /// tabs are moved on to their Downloads folder.
    private func prepareDownloads(lease: Lease) async {
        guard let page else { return }
        let base = configuration.downloadsDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("swiftagentharness-downloads")
        let folder = base.appendingPathComponent(lease.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        downloadsFolder = folder
        var params: [String: JSON] = ["behavior": .string("allow"), "downloadPath": .string(folder.path), "eventsEnabled": .boolean(true)]
        if profile == .throwaway { params["browserContextId"] = .string(page.contextID) }
        _ = try? await page.session.connection.send("Browser.setDownloadBehavior", params)
    }

    private var tabSessions: Set<String> {
        Set(([page] + otherTabs.map { Optional($0) }).compactMap { $0?.sessionID })
    }

    private func isAgentTarget(_ info: JSON) -> Bool {
        guard let page, info[wire: "type"]?.wireString == "page", info[wire: "browserContextId"]?.wireString == page.contextID else {
            return false
        }
        // In the user's profile every tab shares the context; only tabs the agent's own tabs open are its.
        guard profile == .user else { return true }
        let opener = info[wire: "openerId"]?.wireString
        return ([page] + otherTabs).contains { $0.targetID == opener }
    }

    /// A tab a lease's tab opened becomes the active tab, under the same grants and network policy.
    private func adoptTab(targetID: String, url: String) async {
        guard let page, page.targetID != targetID, !otherTabs.contains(where: { $0.targetID == targetID }) else { return }
        let connection = page.session.connection
        if let reason = configuration.network.evaluate(url: url).denialReason {
            _ = try? await connection.send("Target.closeTarget", ["targetId": .string(targetID)])
            notices.append("The page opened a new tab, which was closed: network policy blocks it (\(reason)).")
            return
        }
        guard var tab = try? await attach(session: page.session, contextID: page.contextID, targetID: targetID) else { return }
        tab.url = url
        if casting { _ = try? await send("Page.stopScreencast") }
        otherTabs.append(page)
        self.page = tab
        if casting { await startScreencast() }
        notices.append("The page opened a new tab (\(url)); it is now the active tab. Observe a tab by id to switch.")
    }

    private func switchTab(to targetID: String) async throws {
        guard let page, page.targetID != targetID else { return }
        guard let index = otherTabs.firstIndex(where: { $0.targetID == targetID }) else {
            throw DisplayTargetError.unsupported("tab \(targetID) is not one of this lease's tabs")
        }
        if casting { _ = try? await send("Page.stopScreencast") }
        let next = otherTabs.remove(at: index)
        otherTabs.append(page)
        self.page = next
        if casting { await startScreencast() }
    }

    private func handle(_ event: CDPEvent) async {
        guard let page else { return }
        let connection = page.session.connection
        switch event.method {
        case "Page.javascriptDialogOpening" where event.sessionID.map(tabSessions.contains) == true:
            // The page waits on the dialog, and so does the agent: the next observation shows it to be answered.
            dialogs[event.sessionID ?? ""] = Dialog(
                type: event.params[wire: "type"]?.wireString ?? "alert",
                message: event.params[wire: "message"]?.wireString ?? "",
                promptText: event.params[wire: "defaultPrompt"]?.wireString ?? ""
            )
        case "Page.javascriptDialogClosed":
            if let session = event.sessionID { dialogs[session] = nil }
        case "Page.downloadWillBegin" where event.sessionID.map(tabSessions.contains) == true:
            if let guid = event.params[wire: "guid"]?.wireString { agentDownloads.insert(guid) }
        case "Browser.downloadWillBegin":
            guard let guid = event.params[wire: "guid"]?.wireString else { return }
            let name = (event.params[wire: "suggestedFilename"]?.wireString).flatMap { $0.isEmpty ? nil : $0 } ?? guid
            downloadsByGUID[guid] = Download(name: name, completed: false)
            if profile == .throwaway { agentDownloads.insert(guid) }
        case "Browser.downloadProgress":
            guard let guid = event.params[wire: "guid"]?.wireString, var download = downloadsByGUID[guid],
                  event.params[wire: "state"]?.wireString == "completed", let folder = downloadsFolder else { return }
            download.completed = true
            downloadsByGUID[guid] = download
            let file = folder.appendingPathComponent(download.name)
            if agentDownloads.contains(guid) {
                let keep = profile == .throwaway
                    ? " It is deleted when the task ends unless you keep it with \(ComputerUseToolProvider.keepDownloadsToolName)."
                    : ""
                notices.append("The page downloaded \(download.name.prefix(120)) to the lease's downloads folder; it wasn't opened.\(keep)")
            } else if let home = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                // The user's own download, caught by the lease's folder: it goes where the user expects it.
                try? FileManager.default.moveItem(at: file, to: home.appendingPathComponent(download.name))
                downloadsByGUID[guid] = nil
            }
        case "Target.targetDestroyed":
            guard let id = event.params[wire: "targetId"]?.wireString else { return }
            otherTabs.removeAll { $0.targetID == id }
            if page.targetID == id, let next = otherTabs.popLast() {
                self.page = next
                notices.append("The active tab closed; the previous tab is active again.")
            }
        case "Target.targetInfoChanged", "Target.targetCreated":
            guard let info = event.params[wire: "targetInfo"], let other = info[wire: "targetId"]?.wireString else { return }
            let url = info[wire: "url"]?.wireString ?? ""
            if other == page.targetID {
                self.page?.url = url
                return
            }
            if let index = otherTabs.firstIndex(where: { $0.targetID == other }) {
                otherTabs[index].url = url
                return
            }
            guard isAgentTarget(info), !url.isEmpty, url != "about:blank" else { return }
            await adoptTab(targetID: other, url: url)
        case "Page.screencastFrame" where event.sessionID == page.sessionID:
            if let frame = event.params[wire: "sessionId"] {
                _ = try? await connection.send("Page.screencastFrameAck", .object(["sessionId": frame]), session: page.sessionID)
            }
            guard let liveFeed, let encoded = event.params[wire: "data"]?.wireString, let jpeg = Data(base64Encoded: encoded) else { return }
            let metadata = event.params[wire: "metadata"]
            let width = metadata?[wire: "deviceWidth"]?.wireNumber.map { Int($0.rounded()) } ?? configuration.viewport.width
            let height = metadata?[wire: "deviceHeight"]?.wireNumber.map { Int($0.rounded()) } ?? configuration.viewport.height
            await liveViewServer?.publish(DisplayLiveViewFrame(jpeg: jpeg, width: width, height: height), to: liveFeed)
        default:
            break
        }
    }

    // MARK: - Live view

    private func startScreencast() async {
        _ = try? await send("Page.startScreencast", [
            "format": .string("jpeg"),
            "quality": .integer(70),
            "maxWidth": .integer(configuration.viewport.width),
            "maxHeight": .integer(configuration.viewport.height),
        ])
    }

    private func viewersChanged(_ count: Int) async {
        guard page != nil else { return }
        if count > 0, !casting {
            casting = true
            await startScreencast()
        } else if count == 0, casting {
            casting = false
            _ = try? await send("Page.stopScreencast")
        }
    }

    /// A viewer's input during takeover. Outside takeover the server drops it first; this check is the second gate.
    private func liveInput(_ input: DisplayLiveViewInput) async {
        guard takeoverActive, page != nil else { return }
        let width = Double(configuration.viewport.width), height = Double(configuration.viewport.height)
        func clamped(_ x: Double, _ y: Double) -> DisplayPoint {
            DisplayPoint(x: min(max(x, 0), width - 1), y: min(max(y, 0), height - 1))
        }
        switch input {
        case .mouse(let action, let x, let y, let button, let clickCount, let modifiers):
            let type = switch action {
            case .down: "mousePressed"
            case .up: "mouseReleased"
            case .move: "mouseMoved"
            }
            let held = action == .up ? 0 : button.map(CDPInput.buttonMask) ?? 0
            try? await mouse(type, clamped(x, y), button: button, buttons: held, clickCount: action == .move ? 0 : clickCount, modifiers: CDPInput.modifierMask(modifiers))
        case .wheel(let x, let y, let dx, let dy, let modifiers):
            let point = clamped(x, y)
            _ = try? await send("Input.dispatchMouseEvent", [
                "type": .string("mouseWheel"),
                "x": .double(point.x),
                "y": .double(point.y),
                "deltaX": .double(dx),
                "deltaY": .double(dy),
                "modifiers": .integer(CDPInput.modifierMask(modifiers)),
            ])
        case .key(let down, let key, let code, let keyCode, let text, let modifiers):
            var params: [String: JSON] = [
                "type": .string(down ? (text == nil ? "rawKeyDown" : "keyDown") : "keyUp"),
                "key": .string(key),
                "code": .string(code),
                "windowsVirtualKeyCode": .integer(keyCode),
                "modifiers": .integer(CDPInput.modifierMask(modifiers)),
            ]
            if down, let text {
                params["text"] = .string(text)
                params["unmodifiedText"] = .string(text)
            }
            let commands = down && key.count == 1 ? CDPInput.commands(for: KeyCombo(modifiers: modifiers, key: key)) : []
            if !commands.isEmpty { params["commands"] = .array(commands.map(JSON.string)) }
            _ = try? await send("Input.dispatchKeyEvent", params)
        case .text(let text):
            _ = try? await send("Input.insertText", ["text": .string(text)])
        }
    }

    // MARK: - Perception

    public func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        try await requireLease(lease)
        guard !takeoverActive else { throw DisplayTargetError.unsupported("the user has taken over; capture is paused") }
        if case .tab(let tab) = request.scope { try await switchTab(to: tab) }
        let page = try await self.page(of: lease)
        observationCounter += 1
        let id: ObservationID = "o_\(observationCounter)"
        let now = Date()
        if let dialog = dialogs[page.sessionID] {
            return dialogObservation(dialog, id: id, page: page, at: now)
        }
        let wantsTree = request.modes.contains(.dom) || request.modes.contains(.accessibility)
        let state: ManagedBrowserPageSnapshot = wantsTree
            ? try await evaluate(ManagedBrowserDOM.call("snapshot", [String(configuration.maxElements)]))
            : try await pageState()
        let treeAt = Date()
        // Observations are scoped to granted domains: a page on any other domain is reported by URL only.
        guard grants.tier(forURL: state.url) != nil else {
            return urlOnlyObservation(state, id: id, page: page, at: now)
        }

        let viewport = viewportRect(state)
        var captured = viewport
        if case .region(let region) = request.scope {
            captured = DisplayRect(
                x: max(viewport.minX, region.minX),
                y: max(viewport.minY, region.minY),
                width: min(viewport.maxX, region.maxX) - max(viewport.minX, region.minX),
                height: min(viewport.maxY, region.maxY) - max(viewport.minY, region.minY)
            )
            guard captured.width >= 1, captured.height >= 1 else { throw DisplayTargetError.unsupported("the region lies outside the page") }
        }

        var image: ObservationImage?
        if request.modes.contains(.pixels) {
            let isZoom = if case .region = request.scope { true } else { false }
            let scale = Self.scale(for: captured, limit: request.maxImage, zoom: isZoom)
            let shot = try await page.session.connection.send("Page.captureScreenshot", [
                "format": .string("png"),
                "captureBeyondViewport": .boolean(false),
                "clip": .object([
                    "x": .double(captured.x + state.scrollX),
                    "y": .double(captured.y + state.scrollY),
                    "width": .double(captured.width),
                    "height": .double(captured.height),
                    "scale": .double(scale),
                ]),
            ], session: page.sessionID)
            guard let encoded = shot[wire: "data"]?.wireString, let data = Data(base64Encoded: encoded) else {
                throw DisplayTargetError.driverFailure("the screenshot was empty")
            }
            let size = Self.pngSize(data) ?? ImagePixelSize(
                width: Int((captured.width * scale).rounded()),
                height: Int((captured.height * scale).rounded())
            )
            image = ObservationImage(
                blobRef: "browser:\(id)",
                data: data,
                mediaType: "image/png",
                geometry: ScreenshotGeometry(capturedRect: captured, imageSize: size, scaleFactor: 1),
                capturedAt: Date()
            )
        }

        var tree: ObservationTree?
        if wantsTree {
            let text = ManagedBrowserDOM.render(state, observationID: id) + tabsLine(active: page) + takeNotices()
            tree = ObservationTree(
                text: text,
                elements: ManagedBrowserDOM.elements(state, url: state.url),
                capturedAt: treeAt,
                truncated: state.omitted.map { "\($0) elements past the cap of \(configuration.maxElements)" },
                returnTarget: state.submit
            )
        }
        retain(
            ObservationMeta(
                doc: state.doc,
                scrollX: state.scrollX,
                scrollY: state.scrollY,
                elements: Dictionary((state.elements ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ),
            for: id
        )
        return DisplayObservation(
            id: id,
            at: now,
            target: ObservationTarget(tabID: page.targetID, url: state.url, pageBounds: captured, bounds: captured),
            image: image,
            tree: tree
        )
    }

    private func takeNotices() -> String {
        guard !notices.isEmpty else { return "" }
        defer { notices.removeAll() }
        return "\n" + notices.map { "note: \($0)" }.joined(separator: "\n")
    }

    private func tabsLine(active page: Page) -> String {
        guard !otherTabs.isEmpty else { return "" }
        let others = otherTabs.map { "\($0.targetID) \($0.url ?? "")" }.joined(separator: "; ")
        return "\nother tabs: \(others)"
    }

    private func urlOnlyObservation(_ state: ManagedBrowserPageSnapshot, id: ObservationID, page: Page, at now: Date) -> DisplayObservation {
        retain(ObservationMeta(doc: state.doc, scrollX: state.scrollX, scrollY: state.scrollY, elements: [:]), for: id)
        let text = "page url=\(state.url) obs=\(id)\n(this page's domain isn't granted, so only its URL is reported)"
            + tabsLine(active: page) + takeNotices()
        return DisplayObservation(
            id: id,
            at: now,
            target: ObservationTarget(tabID: page.targetID, url: state.url, pageBounds: viewportRect(state), bounds: viewportRect(state)),
            tree: ObservationTree(text: text, elements: [:], capturedAt: now)
        )
    }

    /// The page is paused on a dialog: its buttons, and a prompt's field, are the elements, answered with an
    /// explicit press or click. The page can't be read or drawn until it is answered.
    private func dialogObservation(_ dialog: Dialog, id: ObservationID, page: Page, at now: Date) -> DisplayObservation {
        let url = page.url ?? ""
        var elements: [String: ElementRef] = [:]
        var lines = ["dialog \(dialog.type) \(Self.quoted(dialog.message)) url=\(url) obs=\(id)"]
        for (ref, label, _) in Self.dialogButtons(dialog.type) {
            elements[ref] = ElementRef(id: ref, role: "button", label: label, url: url)
            lines.append("  [\(ref)] button \(Self.quoted(label))")
        }
        if dialog.type == "prompt" {
            elements["d3"] = ElementRef(id: "d3", role: "textbox", label: "Answer", url: url, value: dialog.promptText, isFocused: true)
            lines.append("  [d3] textbox \"Answer\" value=\(Self.quoted(dialog.promptText)) focused")
        }
        lines.append("(the page waits on this dialog; answer it with one of its buttons)")
        retain(ObservationMeta(doc: nil, scrollX: 0, scrollY: 0, elements: [:], dialog: true), for: id)
        return DisplayObservation(
            id: id,
            at: now,
            target: ObservationTarget(tabID: page.targetID, url: url, bounds: DisplayRect(x: 0, y: 0, width: Double(configuration.viewport.width), height: Double(configuration.viewport.height))),
            tree: ObservationTree(text: lines.joined(separator: "\n") + takeNotices(), elements: elements, capturedAt: now, returnTarget: "d1")
        )
    }

    /// The dialog's buttons: ref, label, and whether it accepts.
    static func dialogButtons(_ type: String) -> [(ref: String, label: String, accepts: Bool)] {
        switch type {
        case "alert": [("d1", "OK", true)]
        case "beforeunload": [("d1", "Leave", true), ("d2", "Stay", false)]
        default: [("d1", "OK", true), ("d2", "Cancel", false)]
        }
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.prefix(300).replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// Answers the paused dialog, or refuses anything else while it is open.
    private func answerDialog(_ dialog: Dialog, action: ComputerAction, page: Page) async -> ActionOutcome {
        func respond(_ accept: Bool) async -> ActionOutcome {
            var params: [String: JSON] = ["accept": .boolean(accept)]
            if dialog.type == "prompt", accept { params["promptText"] = .string(dialog.promptText) }
            _ = try? await page.session.connection.send("Page.handleJavaScriptDialog", params, session: page.sessionID)
            dialogs[page.sessionID] = nil
            return ActionOutcome(action: 0, effect: .unverifiable, evidence: "answered the \(dialog.type) dialog: \(accept ? "accepted" : "dismissed")", escalation: .observe)
        }
        let buttons = Self.dialogButtons(dialog.type)
        switch action {
        case .click(.ref(let ref, _), _, _, _), .press(.ref(let ref, _)):
            if let button = buttons.first(where: { $0.ref == ref }) { return await respond(button.accepts) }
        case .type(let text, let into, _) where dialog.type == "prompt" && (into == nil || into?.elementRef == "d3"):
            var updated = dialog
            updated.promptText = text.hasSuffix("\n") ? String(text.dropLast()) : text
            dialogs[page.sessionID] = updated
            if text.hasSuffix("\n") { return await respond(true) }
            return ActionOutcome(action: 0, effect: .confirmed, evidence: "typed the prompt's answer")
        case .setValue(.ref("d3", _), let value) where dialog.type == "prompt":
            var updated = dialog
            updated.promptText = value
            dialogs[page.sessionID] = updated
            return ActionOutcome(action: 0, effect: .confirmed, evidence: "set the prompt's answer")
        case .key(let combo, _) where combo.modifiers.isEmpty && combo.key == "return":
            return await respond(true)
        case .key(let combo, _) where combo.modifiers.isEmpty && combo.key == "escape" && buttons.count > 1:
            return await respond(false)
        case .observe, .zoom, .wait, .waitFor:
            return ActionOutcome(action: 0, effect: .confirmed)
        default:
            break
        }
        return ActionOutcome(
            action: 0,
            effect: .refused,
            evidence: "a \(dialog.type) dialog is open: answer it with one of its buttons first",
            escalation: .observe
        )
    }

    /// Files the lease's tabs downloaded into its folder.
    public func downloads(_ lease: Lease) async -> [DisplayDownload] {
        guard let folder = downloadsFolder else { return [] }
        return downloadsByGUID
            .filter { agentDownloads.contains($0.key) }
            .map { _, download in
                DisplayDownload(
                    name: download.name,
                    path: folder.appendingPathComponent(download.name).path,
                    completed: download.completed,
                    disposable: profile == .throwaway
                )
            }
            .sorted { $0.name < $1.name }
    }

    /// The screenshot scale that keeps the image inside the model's limits. Chromium renders at that scale, so the
    /// image needs no resizing; a zoom renders at up to twice the CSS resolution.
    static func scale(for rect: DisplayRect, limit: ObservationImageLimit?, zoom: Bool) -> Double {
        var scale = zoom ? 2.0 : 1.0
        if let limit {
            scale = min(scale, Double(limit.longEdgePx) / max(rect.width, rect.height))
            if let pixels = limit.maxPixels { scale = min(scale, (Double(pixels) / (rect.width * rect.height)).squareRoot()) }
        }
        return max(0.05, scale)
    }

    static func pngSize(_ data: Data) -> ImagePixelSize? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, bytes[0..<8] == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] else { return nil }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        return ImagePixelSize(width: width, height: height)
    }

    // MARK: - Action

    public func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        try await requireLease(lease)
        guard !takeoverActive else { throw DisplayTargetError.unsupported("the user has taken over; agent input is paused") }
        var outcomes: [ActionOutcome] = []
        for (index, action) in batch.actions.enumerated() {
            let page = try await self.page(of: lease)
            if let dialog = dialogs[page.sessionID] {
                var outcome = await answerDialog(dialog, action: action, page: page)
                outcome.action = index
                outcomes.append(outcome)
                if outcome.effect.stopsBatch || outcome.escalation == .observe { break }
                continue
            }
            let started = Date()
            let before = try? await pageState()
            var outcome = await perform(action, page: page)
            if let dialog = dialogs[page.sessionID] {
                outcome.evidence = [outcome.evidence, "the page opened a \(dialog.type) dialog, which waits on an answer"]
                    .compactMap { $0 }.joined(separator: "; ")
                outcome.escalation = .observe
            } else if outcome.effect.mayHaveBeenDelivered, Self.mayNavigate(action) {
                outcome = await settle(outcome, before: before)
            }
            let denials = await page.session.networkDenials(started)
            if !denials.isEmpty {
                let blocked = denials.prefix(3).map { "\($0.host) (\($0.reason))" }.joined(separator: "; ")
                outcome.evidence = [outcome.evidence, "network policy blocked \(blocked)"].compactMap { $0 }.joined(separator: "; ")
            }
            outcome.action = index
            outcomes.append(outcome)
            if outcome.effect.stopsBatch { break }
        }
        return outcomes
    }

    private func perform(_ action: ComputerAction, page: Page) async -> ActionOutcome {
        do {
            switch action {
            case .click(let at, let button, let count, let modifiers):
                let point: DisplayPoint
                switch try await resolvePoint(at) {
                case .success(let resolved): point = resolved
                case .failure(let refusal): return refusal.outcome
                }
                let mask = CDPInput.modifierMask(modifiers)
                try await mouse("mouseMoved", point, modifiers: mask)
                for click in 1...max(1, min(count, 3)) {
                    try await mouse("mousePressed", point, button: button, buttons: CDPInput.buttonMask(button), clickCount: click, modifiers: mask)
                    try await mouse("mouseReleased", point, button: button, clickCount: click, modifiers: mask)
                }
                lastPointer = point
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "clicked at (\(Int(point.x)), \(Int(point.y)))")
            case .move(let to):
                let point: DisplayPoint
                switch try await resolvePoint(to) {
                case .success(let resolved): point = resolved
                case .failure(let refusal): return refusal.outcome
                }
                try await mouse("mouseMoved", point)
                lastPointer = point
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "pointer moved")
            case .drag(let path, let modifiers):
                guard path.count >= 2 else { return refused("a drag needs at least two points") }
                var points: [DisplayPoint] = []
                for target in path {
                    switch try await resolvePoint(target, scroll: false) {
                    case .success(let point): points.append(point)
                    case .failure(let refusal): return refusal.outcome
                    }
                }
                let mask = CDPInput.modifierMask(modifiers)
                try await mouse("mouseMoved", points[0], modifiers: mask)
                try await mouse("mousePressed", points[0], button: .left, buttons: 1, clickCount: 1, modifiers: mask)
                do {
                    for (from, to) in zip(points, points.dropFirst()) {
                        for step in 1...8 {
                            let t = Double(step) / 8
                            let point = DisplayPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                            try await mouse("mouseMoved", point, buttons: 1, modifiers: mask)
                        }
                    }
                } catch {
                    try? await mouse("mouseReleased", points[points.count - 1], button: .left, clickCount: 1, modifiers: mask)
                    throw error
                }
                try await mouse("mouseReleased", points[points.count - 1], button: .left, clickCount: 1, modifiers: mask)
                lastPointer = points.last
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "dragged through \(points.count) points")
            case .pointer(let state):
                let point = lastPointer ?? DisplayPoint(x: Double(configuration.viewport.width) / 2, y: Double(configuration.viewport.height) / 2)
                try await mouse(state == .down ? "mousePressed" : "mouseReleased", point, button: .left, buttons: state == .down ? 1 : 0, clickCount: 1)
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "pointer \(state.rawValue)")
            case .scroll(let at, let dx, let dy, let unit):
                var point = lastPointer ?? DisplayPoint(x: Double(configuration.viewport.width) / 2, y: Double(configuration.viewport.height) / 2)
                if let at {
                    switch try await resolvePoint(at, scroll: false) {
                    case .success(let resolved): point = resolved
                    case .failure(let refusal): return refusal.outcome
                    }
                }
                let factor = unit == .line ? 40.0 : 1.0
                try await send("Input.dispatchMouseEvent", [
                    "type": .string("mouseWheel"),
                    "x": .double(point.x), "y": .double(point.y),
                    "deltaX": .double(dx * factor), "deltaY": .double(dy * factor),
                ])
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "scrolled")
            case .type(let text, let into, let mode):
                switch into {
                case .ref(let ref, let observation)?:
                    if mode == .setValue { return try await setValue(ref, observation: observation, value: text) }
                    if case .failure(let refusal) = try await element(ref, observation: observation, function: "focus") { return refusal.outcome }
                case .point?:
                    guard mode != .setValue else { return refused("set-value needs an element ref") }
                    switch try await resolvePoint(into!) {
                    case .success(let point):
                        try await mouse("mousePressed", point, button: .left, buttons: 1, clickCount: 1)
                        try await mouse("mouseReleased", point, button: .left, clickCount: 1)
                    case .failure(let refusal):
                        return refusal.outcome
                    }
                case nil:
                    guard mode != .setValue else { return refused("set-value needs an element ref") }
                }
                return try await typeText(text)
            case .key(let combo, let repeatCount):
                guard let events = CDPInput.keyEvents(combo) else { return refused("\(combo) names no key") }
                for _ in 0..<max(1, min(repeatCount, 100)) {
                    try await send("Input.dispatchKeyEvent", events.down)
                    try await send("Input.dispatchKeyEvent", events.up)
                }
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "\(combo) sent")
            case .hold(let combo, let milliseconds):
                guard let events = CDPInput.keyEvents(combo) else { return refused("\(combo) names no key") }
                try await send("Input.dispatchKeyEvent", events.down)
                try? await Task.sleep(for: .milliseconds(max(0, min(milliseconds, 10_000))))
                try await send("Input.dispatchKeyEvent", events.up)
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "\(combo) held \(milliseconds) ms")
            case .press(let at):
                guard let ref = at.elementRef else { return refused("press needs an element ref") }
                switch try await element(ref, observation: at.observation, function: "press") {
                case .success: return ActionOutcome(action: 0, effect: .unverifiable, evidence: "\(ref) pressed through the DOM")
                case .failure(let refusal): return refusal.outcome
                }
            case .setValue(let at, let value):
                guard let ref = at.elementRef else { return refused("set-value needs an element ref") }
                return try await setValue(ref, observation: at.observation, value: value)
            case .openURL(let url):
                if let reason = configuration.network.evaluate(url: url).denialReason {
                    return refused("network policy blocks \(url): \(reason)")
                }
                let result = try await send("Page.navigate", ["url": .string(url)])
                if let failure = result[wire: "errorText"]?.wireString {
                    return ActionOutcome(action: 0, effect: .unverifiable, evidence: "the page failed to load (\(failure))", escalation: .observe)
                }
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "navigation started")
            case .wait(let milliseconds):
                try? await Task.sleep(for: .milliseconds(max(0, min(milliseconds, 60_000))))
                return ActionOutcome(action: 0, effect: .confirmed, evidence: "waited \(milliseconds) ms")
            case .waitFor:
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "the driver does not evaluate conditions; observe to check", escalation: .observe)
            case .menu:
                return refused("the managed browser has no menus; act on the page instead")
            case .launch:
                return refused("the managed browser runs no apps; open a page with open-url")
            case .observe, .zoom:
                return refused("observe through the session, not as a driver action")
            case .script(let language, let source, let timeout):
                guard language == .javascript else { return refused("the managed browser runs only JavaScript") }
                return try await runScript(source, timeoutMilliseconds: timeout)
            }
        } catch {
            return ActionOutcome(action: 0, effect: .unverifiable, evidence: "driver error: \(error)", escalation: .observe)
        }
    }

    /// Runs the model's script in a fresh isolated world: it shares the DOM, but neither the page's JavaScript nor the
    /// world the tree builder keeps its refs in, so it can't forge what observations report.
    private func runScript(_ source: String, timeoutMilliseconds timeout: Int) async throws -> ActionOutcome {
        let tree = try await send("Page.getFrameTree")
        guard let frameID = tree[wire: "frameTree"]?[wire: "frame"]?[wire: "id"]?.wireString else {
            throw DisplayTargetError.driverFailure("the page has no main frame")
        }
        let world = try await send("Page.createIsolatedWorld", [
            "frameId": .string(frameID),
            "worldName": .string(ManagedBrowserScript.worldName),
            "grantUniveralAccess": .boolean(false),
        ])
        guard let context = world[wire: "executionContextId"]?.wireInt else { throw DisplayTargetError.driverFailure("no script context") }
        let result: JSON
        do {
            result = try await send("Runtime.evaluate", [
                "expression": .string(ManagedBrowserScript.expression(source, timeoutMilliseconds: timeout)),
                "contextId": .integer(context),
                "awaitPromise": .boolean(true),
                "returnByValue": .boolean(true),
                "userGesture": .boolean(true),
                "timeout": .integer(timeout),
            ])
        } catch let error as CDPError {
            // Chromium answers a script it terminated at `timeout`, such as a busy loop, with an internal error.
            return ActionOutcome(
                action: 0, effect: .partial,
                evidence: "stopped after \(timeout) ms (\(error.message)); it may have run in part", escalation: .observe
            )
        }
        if let details = result[wire: "exceptionDetails"] {
            let text = details[wire: "exception"]?[wire: "description"]?.wireString ?? details[wire: "text"]?.wireString ?? "script error"
            return ActionOutcome(action: 0, effect: .partial, evidence: "stopped: \(ManagedBrowserScript.clip(text, to: 500))", escalation: .observe)
        }
        let reply = result[wire: "result"]?[wire: "value"]?.wireString.flatMap { try? JSONDecoder().decode(ManagedBrowserScript.Reply.self, from: Data($0.utf8)) }
        return ManagedBrowserScript.outcome(reply, timeoutMilliseconds: timeout)
    }

    /// Text goes in as inserted text; line breaks and tabs are pressed as keys, so they submit and move focus as
    /// typing would.
    private func typeText(_ text: String) async throws -> ActionOutcome {
        for segment in Self.typingSegments(text) {
            switch segment {
            case .text(let chunk):
                try await send("Input.insertText", ["text": .string(chunk)])
            case .key(let combo):
                guard let events = CDPInput.keyEvents(combo) else { continue }
                try await send("Input.dispatchKeyEvent", events.down)
                try await send("Input.dispatchKeyEvent", events.up)
            }
        }
        return ActionOutcome(action: 0, effect: .unverifiable, evidence: "typed \(text.count) characters")
    }

    enum TypingSegment: Equatable {
        case text(String)
        case key(KeyCombo)
    }

    static func typingSegments(_ text: String) -> [TypingSegment] {
        var segments: [TypingSegment] = []
        var chunk = ""
        for character in text {
            switch character {
            case "\n", "\r\n", "\r", "\t":
                if !chunk.isEmpty { segments.append(.text(chunk)) }
                chunk = ""
                segments.append(.key(KeyCombo(modifiers: [], key: character == "\t" ? "tab" : "return")))
            default:
                chunk.append(character)
            }
        }
        if !chunk.isEmpty { segments.append(.text(chunk)) }
        return segments
    }

    private func setValue(_ ref: String, observation: ObservationID, value: String) async throws -> ActionOutcome {
        switch try await element(ref, observation: observation, function: "setValue", extra: [ManagedBrowserDOM.literal(value)]) {
        case .failure(let refusal):
            return refusal.outcome
        case .success(let result):
            guard let readBack = result.value else { return ActionOutcome(action: 0, effect: .unverifiable, evidence: "value written; not read back") }
            let role = meta(observation)?.elements[ref]?.role ?? ""
            if readBack == value || Self.choiceRoles.contains(role) {
                return ActionOutcome(action: 0, effect: .confirmed, evidence: "value read back")
            }
            return ActionOutcome(action: 0, effect: .partial, evidence: "the field holds \(readBack.count) characters after writing \(value.count)", escalation: .observe)
        }
    }

    /// Waits for a navigation the action started, then holds the page to the network policy. A final URL it blocks
    /// is cleared, so the agent never works on it.
    private func settle(_ outcome: ActionOutcome, before: ManagedBrowserPageSnapshot?) async -> ActionOutcome {
        var outcome = outcome
        try? await Task.sleep(for: configuration.settleDelay)
        let deadline = ContinuousClock.now + configuration.navigationTimeout
        var state = try? await pageState()
        while let current = state, current.readyState != "complete", ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            state = try? await pageState()
        }
        guard let state else { return outcome }
        // Chromium's own error page, shown when a load fails (including a connection the proxy refused).
        if state.url.hasPrefix("chrome-error:") {
            if outcome.evidence?.contains("failed to load") != true {
                outcome.evidence = [outcome.evidence, "the page failed to load"].compactMap { $0 }.joined(separator: "; ")
            }
            outcome.escalation = .observe
            return outcome
        }
        if let reason = configuration.network.evaluate(url: state.url).denialReason {
            _ = try? await send("Page.navigate", ["url": .string("about:blank")])
            outcome.effect = .partial
            outcome.evidence = "the page went to \(state.url), which network policy blocks (\(reason)); it was cleared"
            outcome.escalation = .observe
            return outcome
        }
        if let before, state.url != before.url || state.doc != before.doc {
            let host = URLComponents(string: state.url)?.host ?? state.url
            outcome.effect = .confirmed
            outcome.evidence = [outcome.evidence, "the page navigated to \(host)"].compactMap { $0 }.joined(separator: "; ")
            if state.readyState != "complete" { outcome.evidence? += " and is still loading" }
        } else if outcome.effect != .unverifiable {
            return outcome
        } else if let before, state.mutations != before.mutations || state.focused != before.focused || state.scrollY != before.scrollY || state.scrollX != before.scrollX {
            outcome.evidence = [outcome.evidence, "the page changed"].compactMap { $0 }.joined(separator: "; ")
        } else if before != nil {
            outcome.evidence = [outcome.evidence, "no change seen in the page's DOM"].compactMap { $0 }.joined(separator: "; ")
        }
        return outcome
    }

    /// Roles whose read-back is the choice made, not the text written.
    static let choiceRoles: Set<String> = ["checkbox", "radio", "switch", "combobox", "listbox"]

    private static func mayNavigate(_ action: ComputerAction) -> Bool {
        switch action {
        case .wait, .waitFor, .observe, .zoom, .menu, .launch, .move: return false
        default: return true
        }
    }

    // MARK: - Resolution

    struct Refusal: Error {
        var message: String
        var escalation: ActionEscalation? = .observe

        var outcome: ActionOutcome {
            ActionOutcome(action: 0, effect: .refused, evidence: message, escalation: escalation)
        }
    }

    /// A ref is looked up live in the document it was observed in and refused if its role or label changed; a point
    /// is refused if the page navigated or scrolled since its observation, since the content under it moved.
    private func resolvePoint(_ target: ActionTarget, scroll: Bool = true) async throws -> Result<DisplayPoint, Refusal> {
        guard let meta = meta(target.observation) else {
            return .failure(Refusal(message: "observation \(target.observation) was not made by this target or is no longer retained"))
        }
        switch target {
        case .point(let point, let observation):
            let state = try await pageState()
            if state.doc != meta.doc { return .failure(Refusal(message: "the page changed since observation \(observation)")) }
            if state.scrollX != meta.scrollX || state.scrollY != meta.scrollY {
                return .failure(Refusal(message: "the page scrolled since observation \(observation)"))
            }
            guard viewportRect(state).contains(point) else { return .failure(Refusal(message: "the point lies outside the page")) }
            return .success(point)
        case .ref(let ref, let observation):
            let resolved = try await resolve(ref, meta: meta, observation: observation, scroll: scroll)
            switch resolved {
            case .failure(let refusal): return .failure(refusal)
            case .success(let live):
                guard let frame = live.frame, frame.width >= 1, frame.height >= 1 else {
                    return .failure(Refusal(message: "element \(ref) has no size on screen"))
                }
                if live.covered == true {
                    return .failure(Refusal(message: "element \(ref) is covered by \(live.coveredBy.map { "a \($0)" } ?? "another element"); press it, or act on what covers it"))
                }
                return .success(frame.center)
            }
        }
    }

    private func resolve(
        _ ref: String,
        meta: ObservationMeta,
        observation: ObservationID,
        scroll: Bool
    ) async throws -> Result<ManagedBrowserResolvedElement, Refusal> {
        guard let snapshot = meta.elements[ref] else { return .failure(Refusal(message: "element \(ref) is not in observation \(observation)")) }
        let live: ManagedBrowserResolvedElement = try await evaluate(ManagedBrowserDOM.call("resolve", [
            ManagedBrowserDOM.literal(ref), ManagedBrowserDOM.literal(meta.doc ?? ""), scroll ? "true" : "false",
        ]))
        return Self.drift(live, from: snapshot, ref: ref, observation: observation).map { .failure($0) } ?? .success(live)
    }

    static func drift(
        _ live: ManagedBrowserResolvedElement,
        from snapshot: ManagedBrowserPageSnapshot.Element,
        ref: String,
        observation: ObservationID
    ) -> Refusal? {
        if live.error != nil { return Refusal(message: "element \(ref) from observation \(observation) is gone; the page changed") }
        if live.role != snapshot.role {
            return Refusal(message: "element \(ref) changed from \(snapshot.role) to \(live.role ?? "nothing")")
        }
        if (live.name ?? "") != (snapshot.name ?? ""), snapshot.role != "textbox", snapshot.role != "searchbox" {
            return Refusal(message: "element \(ref)'s label changed since observation \(observation)")
        }
        return nil
    }

    /// Runs a semantic library function on a resolved, unchanged element.
    private func element(
        _ ref: String,
        observation: ObservationID,
        function: String,
        extra: [String] = []
    ) async throws -> Result<ManagedBrowserResolvedElement, Refusal> {
        guard let meta = meta(observation) else {
            return .failure(Refusal(message: "observation \(observation) was not made by this target or is no longer retained"))
        }
        if case .failure(let refusal) = try await resolve(ref, meta: meta, observation: observation, scroll: false) { return .failure(refusal) }
        let result: ManagedBrowserResolvedElement = try await evaluate(ManagedBrowserDOM.call(function, [
            ManagedBrowserDOM.literal(ref), ManagedBrowserDOM.literal(meta.doc ?? ""),
        ] + extra))
        if let error = result.error { return .failure(Refusal(message: "\(ref): \(error)")) }
        return .success(result)
    }

    // MARK: - CDP

    private func pageState() async throws -> ManagedBrowserPageSnapshot {
        try await evaluate(ManagedBrowserDOM.call("page"))
    }

    /// Evaluates in the isolated world, recreating it after a navigation destroyed the old one.
    private func evaluate<Value: Decodable>(_ expression: String) async throws -> Value {
        for attempt in 0..<2 {
            let context = try await worldContext(fresh: attempt > 0)
            let result: JSON
            do {
                result = try await send("Runtime.evaluate", [
                    "expression": .string(expression),
                    "contextId": .integer(context),
                    "returnByValue": .boolean(true),
                ])
            } catch let error as CDPError where attempt == 0 && error.message.localizedCaseInsensitiveContains("context") {
                continue
            }
            if let details = result[wire: "exceptionDetails"] {
                let text = details[wire: "exception"]?[wire: "description"]?.wireString ?? details[wire: "text"]?.wireString ?? "script error"
                throw DisplayTargetError.driverFailure("page script failed: \(text.prefix(300))")
            }
            guard let json = result[wire: "result"]?[wire: "value"]?.wireString else {
                throw DisplayTargetError.driverFailure("page script returned nothing")
            }
            return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        }
        throw DisplayTargetError.driverFailure("the page's script context is unavailable")
    }

    private func worldContext(fresh: Bool) async throws -> Int {
        guard var page else { throw DisplayTargetError.leaseNotHeld }
        if !fresh, let world = page.world { return world }
        let tree = try await send("Page.getFrameTree")
        guard let frameID = tree[wire: "frameTree"]?[wire: "frame"]?[wire: "id"]?.wireString else {
            throw DisplayTargetError.driverFailure("the page has no main frame")
        }
        let world = try await send("Page.createIsolatedWorld", [
            "frameId": .string(frameID),
            "worldName": .string(ManagedBrowserDOM.worldName),
            "grantUniveralAccess": .boolean(false),
        ])
        guard let context = world[wire: "executionContextId"]?.wireInt else { throw DisplayTargetError.driverFailure("no script context") }
        page.frameID = frameID
        page.world = context
        self.page = page
        return context
    }

    @discardableResult
    private func send(_ method: String, _ params: [String: JSON] = [:]) async throws -> JSON {
        guard let page else { throw DisplayTargetError.leaseNotHeld }
        let connection = page.session.connection
        let session = page.sessionID
        guard method.hasPrefix("Input.") || method.hasPrefix("Runtime.") else {
            return try await connection.send(method, .object(params), session: session)
        }
        // A JavaScript dialog blocks the page, and Chromium holds input and script replies until it's answered.
        if let reply = try await unlessDialog(session, { try await connection.send(method, .object(params), session: session) }) {
            return reply
        }
        guard method.hasPrefix("Input.") else { throw DisplayTargetError.driverFailure("the page is waiting on a dialog") }
        return .object([:])
    }

    /// Runs `work` unless the tab opens a dialog first, in which case it returns nil and `work` finishes unattended.
    private func unlessDialog<T: Sendable>(
        _ session: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        guard dialogs[session] == nil else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: Result<T, any Error>?.self)
        Task {
            do { continuation.yield(.success(try await work())) } catch { continuation.yield(.failure(error)) }
        }
        let watch = Task { [weak self] in
            while !Task.isCancelled {
                if await self?.hasDialog(session) ?? true {
                    continuation.yield(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer {
            watch.cancel()
            continuation.finish()
        }
        for await first in stream { return try first?.get() }
        return nil
    }

    private func hasDialog(_ session: String) -> Bool {
        dialogs[session] != nil
    }

    private func mouse(
        _ type: String,
        _ point: DisplayPoint,
        button: MouseButton? = nil,
        buttons: Int = 0,
        clickCount: Int = 0,
        modifiers: Int = 0
    ) async throws {
        var params: [String: JSON] = [
            "type": .string(type),
            "x": .double(point.x),
            "y": .double(point.y),
            "modifiers": .integer(modifiers),
            "buttons": .integer(buttons),
            "button": .string(button.map(CDPInput.buttonName) ?? "none"),
        ]
        if clickCount > 0 { params["clickCount"] = .integer(clickCount) }
        try await send("Input.dispatchMouseEvent", params)
    }

    // MARK: - Bookkeeping

    private func viewportRect(_ state: ManagedBrowserPageSnapshot) -> DisplayRect {
        DisplayRect(x: 0, y: 0, width: state.viewportWidth, height: state.viewportHeight)
    }

    private func meta(_ id: ObservationID) -> ObservationMeta? {
        observations[id]
    }

    private func retain(_ meta: ObservationMeta, for id: ObservationID) {
        observations[id] = meta
        observationOrder.append(id)
        while observationOrder.count > configuration.retainedObservations {
            observations.removeValue(forKey: observationOrder.removeFirst())
        }
    }

    private func page(of lease: Lease) async throws -> Page {
        guard let page else { throw DisplayTargetError.leaseNotHeld }
        return page
    }

    private func requireLease(_ lease: Lease) async throws {
        guard await lock.holds(leaseID: lease.id) else { throw DisplayTargetError.leaseNotHeld }
    }

    private func refused(_ reason: String) -> ActionOutcome {
        ActionOutcome(action: 0, effect: .refused, evidence: reason)
    }
}
