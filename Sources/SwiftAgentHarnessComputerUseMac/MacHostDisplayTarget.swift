#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// The user's own Mac as a display target, with the drivers inside this process. Run from a CLI or anything
/// launched from another app it is the development escape hatch, borrowing that app's TCC grants (the terminal's),
/// and its label says so; the production shapes are the signed host app serving this contract over XPC, or a
/// notarized GUI app that embeds the harness and owns its grants (`embeddedInSignedApp`).
public actor MacHostDisplayTarget: DisplayTarget {
    public static let defaultID: DisplayTargetID = "macos-host"

    public struct Configuration: Sendable {
        public var id: DisplayTargetID
        /// The harness's own apps: never captured and never granted, so the model cannot read its transcript,
        /// approval prompts, or the user's chat input off the screen.
        public var excludedBundleIDs: Set<String>
        /// Called when delivery escalates to the foreground and the target activates an app (its bundle id), so
        /// the HUD can announce it.
        public var onForegroundDelivery: (@Sendable (String?) async -> Void)?
        /// Gives the whole screen out as live-view frames and takes a viewer's input during takeover, for a
        /// display host whose harness serves the live view, as in a VM guest. Off for the user's own Mac, whose
        /// screen is theirs.
        public var servesLiveFrames: Bool
        /// The long edge of a live-view frame.
        public var liveFrameLongEdge: Int
        /// This process is a signed GUI app that owns its own grants, so in-process drivers aren't the development
        /// escape hatch and the label doesn't call them that.
        public var embeddedInSignedApp: Bool
        /// Watched during a lease with a listen-only event tap (it needs Input Monitoring): pressing it sends the
        /// holder `stopRequested`, and any other key the user presses sends `userTyping`. `nil` watches nothing.
        public var stopKey: KeyCombo?
        var axBudget: MacAXTraversalBudget
        var permissionProbe: any MacPermissionProbing
        var eventPoster: any MacEventPosting
        var workspace: any MacWorkspaceReading
        /// Tells whether a background delivery changed anything; `nil` uses the live tree-and-pixels probe.
        var deliveryProbe: (any MacDeliveryProbing)?

        public init(
            id: DisplayTargetID = MacHostDisplayTarget.defaultID,
            excludedBundleIDs: Set<String> = Self.defaultExcludedBundleIDs,
            servesLiveFrames: Bool = false,
            liveFrameLongEdge: Int = 1_600,
            stopKey: KeyCombo? = .defaultStopKey,
            embeddedInSignedApp: Bool = false
        ) {
            self.init(id: id, excludedBundleIDs: excludedBundleIDs, permissionProbe: LiveMacPermissionProbe(), eventPoster: LiveMacEventPoster())
            self.servesLiveFrames = servesLiveFrames
            self.liveFrameLongEdge = liveFrameLongEdge
            self.stopKey = stopKey
            self.embeddedInSignedApp = embeddedInSignedApp
        }

        init(
            id: DisplayTargetID = MacHostDisplayTarget.defaultID,
            excludedBundleIDs: Set<String>,
            permissionProbe: any MacPermissionProbing,
            eventPoster: any MacEventPosting,
            workspace: any MacWorkspaceReading = LiveMacWorkspace(),
            axBudget: MacAXTraversalBudget = .default,
            deliveryProbe: (any MacDeliveryProbing)? = nil
        ) {
            self.deliveryProbe = deliveryProbe
            self.id = id
            self.excludedBundleIDs = excludedBundleIDs
            self.permissionProbe = permissionProbe
            self.eventPoster = eventPoster
            self.workspace = workspace
            self.axBudget = axBudget
            self.servesLiveFrames = false
            self.liveFrameLongEdge = 1_600
            self.stopKey = nil
            self.embeddedInSignedApp = false
        }

        public static var defaultExcludedBundleIDs: Set<String> {
            Set([Bundle.main.bundleIdentifier].compactMap { $0 })
        }
    }

    public nonisolated let manifest: DisplayTargetManifest
    private let configuration: Configuration
    private let lock = DisplayTargetLeaseLock()
    private let broker: MacPermissionBroker
    private let capture = MacScreenCapture()
    private let accessibility = MacAccessibilityReader()
    private let input: MacInputInjector
    private var workspace: any MacWorkspaceReading { configuration.workspace }

    private struct ObservationMeta {
        var pid: pid_t?
        var processStart: Date?
        var geometry: ScreenshotGeometry?
    }

    private var observations: [ObservationID: ObservationMeta] = [:]
    private var observationOrder: [ObservationID] = []
    private var observationCounter = 0
    private var takeoverActive = false
    /// The process the latest cited action landed in, with its start time.
    private var cited: (pid: pid_t, start: Date?)?
    private var liveFrameSpace: MacLiveFrameSpace?
    private var liveHeldButton: MouseButton?
    private var grants = ComputerUseGrantSet([])
    private var foregroundAllowed = false
    /// The app that was frontmost before a foreground action, restored on release unless the user moved on.
    private var restoreFrontmost: (previous: pid_t, activated: pid_t)?
    private let eventHub = DisplayTargetEventHub()
    /// Apps whose later actions go to the foreground, after a background action in them changed nothing.
    private var foregroundApps: Set<pid_t> = []
    /// The action being delivered, for choosing its delivery.
    private var currentAction: ComputerAction?
    private var probe: any MacDeliveryProbing {
        configuration.deliveryProbe ?? LiveMacDeliveryProbe(
            accessibility: accessibility,
            capture: capture,
            workspace: workspace,
            grantedBundleIDs: { [weak self] in await self?.grantedBundleIDs ?? [] },
            excludedBundleIDs: configuration.excludedBundleIDs
        )
    }
    private var stopKeyMonitor: MacStopKeyMonitor?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.broker = MacPermissionBroker(probe: configuration.permissionProbe)
        self.input = MacInputInjector(poster: configuration.eventPoster)
        self.manifest = DisplayTargetManifest(
            id: configuration.id,
            label: configuration.embeddedInSignedApp ? "This Mac" : "This Mac (in-process development mode)",
            platform: "macos",
            isolation: .host,
            perception: [.pixels, .accessibility],
            delivery: [.background, .foreground],
            semanticActions: [.press, .setValue, .focus, .menuPath, .launchApp, .openURL],
            multiDisplay: true,
            observerAccess: configuration.servesLiveFrames ? .stream : .none,
            requires: [.screenCapture, .accessibility, .postEvents],
            humanPresence: .shared
        )
    }

    /// The onboarding checklist for this target's permissions.
    public nonisolated func permissionChecklist() -> [MacPermissionChecklistItem] {
        broker.checklist(manifest.requires)
    }

    // MARK: - Lifecycle

    public func lease(_ request: LeaseRequest) async throws -> Lease {
        var granted = request
        granted.grants = request.grants.filter { grant in
            if case .app(let bundleID, _, _) = grant { return !configuration.excludedBundleIDs.contains(bundleID) }
            return true
        }
        let lease = Lease(request: granted, issuedAt: Date())
        try await lock.acquire(leaseID: lease.id, holder: .init(id: request.agentID, isAlive: request.isHolderAlive))
        grants = ComputerUseGrantSet(lease.grants)
        foregroundAllowed = lease.delivery == .foregroundAllowed
        takeoverActive = false
        cited = nil
        foregroundApps = []
        if let stopKey = configuration.stopKey {
            let hub = eventHub
            let leaseID = lease.id
            let monitor = MacStopKeyMonitor(
                stopKey: stopKey,
                onStop: { hub.post(.stopRequested, to: leaseID) },
                onUserKey: { hub.post(.userTyping, to: leaseID) }
            )
            if monitor.start() { stopKeyMonitor = monitor }
        }
        return lease
    }

    public func events(_ lease: Lease) async -> AsyncStream<DisplayTargetEvent> {
        guard await lock.holds(leaseID: lease.id) else { return AsyncStream { $0.finish() } }
        return eventHub.stream(for: lease.id)
    }

    public func release(_ lease: Lease, reason: ReleaseReason) async {
        guard await lock.release(leaseID: lease.id) else { return }
        stopKeyMonitor?.stop()
        stopKeyMonitor = nil
        eventHub.finish(lease.id)
        await input.releaseAll()
        if let restore = restoreFrontmost {
            let frontmost = await workspace.frontmostApp()?.pid
            // User input wins: restore only if the app we activated is still in front.
            if frontmost == restore.activated { _ = await MacAppControl.activate(pid: restore.previous) }
        }
        restoreFrontmost = nil
        observations = [:]
        observationOrder = []
        grants = ComputerUseGrantSet([])
        takeoverActive = false
    }

    public func permissions() async -> PermissionSnapshot {
        broker.snapshot(manifest.requires)
    }

    // MARK: - Perception

    public func describe(_ lease: Lease) async throws -> TargetLayout {
        try await requireLease(lease)
        let displays = await MainActor.run {
            NSScreen.screens.compactMap { screen -> DisplayInfo? in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                let displayID = CGDirectDisplayID(number.uint32Value)
                return DisplayInfo(
                    id: String(displayID),
                    frame: DisplayRect(CGDisplayBounds(displayID)),
                    scaleFactor: Double(screen.backingScaleFactor),
                    isPrimary: CGDisplayIsMain(displayID) != 0
                )
            }
        }
        return TargetLayout(displays: displays, windows: [], tabs: [], focusedApp: await workingApp()?.identity)
    }

    public func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        try await requireLease(lease)
        guard !takeoverActive else { throw DisplayTargetError.unsupported("the user has taken over; capture is paused") }
        observationCounter += 1
        let id: ObservationID = "o_\(observationCounter)"
        let now = Date()
        let grantedApps = grantedBundleIDs
        let wantsPixels = request.modes.contains(.pixels)
        let wantsTree = request.modes.contains(.accessibility)

        var image: ObservationImage?
        var bounds = CGRect.zero
        var pid: pid_t?
        var app: AppIdentity?
        var processStart: Date?

        switch request.scope {
        case .region(let region):
            let shot = try await capture.captureRegion(MacCoordinateSpace.cgRect(region), grantedBundleIDs: grantedApps, excludedBundleIDs: configuration.excludedBundleIDs)
            image = ObservationImage(blobRef: "mac:\(id)", data: shot.data, mediaType: shot.mediaType, geometry: shot.geometry, capturedAt: shot.capturedAt)
            bounds = MacCoordinateSpace.cgRect(shot.geometry.capturedRect)
        case .window(let window):
            guard let running = await workspace.runningApp(pid: window.pid), grantedApps.contains(running.identity.bundleID) else {
                throw DisplayTargetError.unsupported("window \(window.windowID) is not in a granted app")
            }
            pid = running.pid
            app = running.identity
            processStart = running.launchDate
            bounds = MacCoordinateSpace.cgRect(window.bounds)
            if wantsPixels, let windowID = CGWindowID(window.windowID) {
                let shot = try await capture.captureWindow(
                    windowID: windowID,
                    maxLongEdge: request.maxImage?.longEdgePx,
                    maxPixels: request.maxImage?.maxPixels
                )
                image = ObservationImage(blobRef: "mac:\(id)", data: shot.data, mediaType: shot.mediaType, geometry: shot.geometry, capturedAt: shot.capturedAt)
                bounds = MacCoordinateSpace.cgRect(shot.geometry.capturedRect)
            }
        case .display, .tab:
            if let working = await workingApp() {
                pid = working.pid
                app = working.identity
                processStart = working.launchDate
            }
            if wantsPixels {
                var displayID: CGDirectDisplayID?
                if case .display(let raw?) = request.scope { displayID = CGDirectDisplayID(raw) }
                let shot = try await capture.captureDisplay(
                    displayID: displayID,
                    grantedBundleIDs: grantedApps,
                    excludedBundleIDs: configuration.excludedBundleIDs,
                    maxLongEdge: request.maxImage?.longEdgePx,
                    maxPixels: request.maxImage?.maxPixels
                )
                image = ObservationImage(blobRef: "mac:\(id)", data: shot.data, mediaType: shot.mediaType, geometry: shot.geometry, capturedAt: shot.capturedAt)
                bounds = MacCoordinateSpace.cgRect(shot.geometry.capturedRect)
            } else {
                bounds = CGDisplayBounds(CGMainDisplayID())
            }
        }

        var tree: ObservationTree?
        var page: MacAXPage?
        if let pid, let app, grantedApps.contains(app.bundleID) {
            if wantsTree, let snapshot = await accessibility.snapshotFocusedWindow(pid: pid, app: app, observationID: id, budget: configuration.axBudget) {
                tree = ObservationTree(
                    text: snapshot.rendering.text,
                    elements: snapshot.rendering.elements,
                    capturedAt: Date(),
                    truncated: snapshot.truncated,
                    returnTarget: snapshot.defaultButtonRef
                )
                page = snapshot.rendering.page
            } else {
                page = await accessibility.focusedPage(pid: pid)
            }
        }
        retain(ObservationMeta(pid: pid, processStart: processStart, geometry: image?.geometry), for: id)
        return DisplayObservation(
            id: id,
            at: now,
            target: ObservationTarget(
                app: app,
                pid: pid,
                processStart: processStart,
                url: page?.url,
                pageBounds: page?.bounds.map(DisplayRect.init),
                bounds: DisplayRect(bounds)
            ),
            image: image,
            tree: tree
        )
    }

    // MARK: - Action

    public func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        try await requireLease(lease)
        var outcomes: [ActionOutcome] = []
        for (index, action) in batch.actions.enumerated() {
            currentAction = action
            var outcome = await perform(action)
            currentAction = nil
            outcome.action = index
            outcomes.append(outcome)
            if outcome.effect.stopsBatch { break }
        }
        await input.releaseAll()
        return outcomes
    }

    public func takeover(_ lease: Lease, on: Bool) async throws {
        try await requireLease(lease)
        await input.releaseAll()
        liveHeldButton = nil
        takeoverActive = on
    }

    // MARK: - Live frames

    public func liveFrame(_ lease: Lease) async throws -> DisplayLiveViewFrame? {
        try await requireLease(lease)
        guard configuration.servesLiveFrames else { return nil }
        let shot = try await capture.captureLiveFrame(excludedBundleIDs: configuration.excludedBundleIDs, maxLongEdge: configuration.liveFrameLongEdge)
        noteLiveFrame(shot.space)
        return DisplayLiveViewFrame(jpeg: shot.jpeg, width: shot.space.frame.width, height: shot.space.frame.height)
    }

    /// Viewers' points are in the latest frame's space.
    func noteLiveFrame(_ space: MacLiveFrameSpace) {
        liveFrameSpace = space
    }

    public func liveInput(_ lease: Lease, _ viewerInput: DisplayLiveViewInput) async throws {
        try await requireLease(lease)
        guard configuration.servesLiveFrames, takeoverActive, let liveFrameSpace else { return }
        let events = MacLiveInput.events(for: viewerInput, space: liveFrameSpace, held: liveHeldButton)
        if case .mouse(let action, _, _, let button, _, _) = viewerInput {
            if action == .down { liveHeldButton = button } else if action == .up { liveHeldButton = nil }
        }
        await input.post(events, delivery: .foreground)
    }

    private func perform(_ action: ComputerAction) async -> ActionOutcome {
        guard !takeoverActive else { return refused("the user has taken over") }
        switch action {
        case .observe, .zoom:
            return refused("observations go through observe, not act")
        case .script:
            // A desktop script can't be held to the app grants, so the host desktop declares no scripting.
            return refused("this target runs no scripts")
        case .wait(let milliseconds):
            try? await Task.sleep(for: .milliseconds(max(0, milliseconds)))
            return ActionOutcome(action: 0, effect: .confirmed, evidence: "waited \(milliseconds) ms")
        case .waitFor(_, let timeout):
            try? await Task.sleep(for: .milliseconds(max(0, min(timeout, 2_000))))
            return ActionOutcome(action: 0, effect: .unverifiable, evidence: "the driver does not evaluate conditions; observe to check", escalation: .observe)
        case .click(let target, let button, let count, let modifiers):
            if case .ref(let ref, let observation) = target, button == .left, count == 1, modifiers.isEmpty {
                switch await accessibility.press(ref: ref, observation: observation) {
                case .performed(let evidence), .unverifiable(let evidence):
                    return ActionOutcome(action: 0, effect: .unverifiable, evidence: evidence)
                case .refused(let reason):
                    return refused(reason, escalation: .observe)
                case .unsupported:
                    break
                }
            }
            return await pointer(target) { point in MacInputPlanner.click(at: point, button: button, count: count, modifiers: modifiers) }
        case .press(let target):
            guard case .ref(let ref, let observation) = target else {
                return await pointer(target) { MacInputPlanner.click(at: $0, button: .left, count: 1, modifiers: []) }
            }
            switch await accessibility.press(ref: ref, observation: observation) {
            case .performed(let evidence), .unverifiable(let evidence):
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: evidence)
            case .refused(let reason):
                return refused(reason, escalation: .observe)
            case .unsupported:
                return await pointer(target) { MacInputPlanner.click(at: $0, button: .left, count: 1, modifiers: []) }
            }
        case .move(let target):
            return await pointer(target) { MacInputPlanner.move(to: $0) }
        case .drag(let path, let modifiers):
            var points: [CGPoint] = []
            var delivery: MacInputDelivery?
            for target in path {
                switch await resolvePoint(target) {
                case .success(let resolved):
                    points.append(resolved.point)
                    delivery = delivery ?? resolved.delivery
                case .failure(let reason):
                    return refused(reason.message, escalation: .observe)
                }
            }
            guard points.count >= 2, let delivery else { return refused("a drag needs at least two points") }
            return await deliver(MacInputPlanner.drag(points, modifiers: modifiers), delivery: delivery, evidence: "drag posted")
        case .pointer(let state):
            let point = await input.currentPoint
            let event: MacInputEvent = state == .down ? .mouseDown(point, .left, 1, []) : .mouseUp(point, .left, 1, [])
            guard let delivery = await keyboardDelivery() else { return noWorkingApp() }
            return await deliver([event], delivery: delivery, evidence: "pointer \(state.rawValue)")
        case .scroll(let target, let dx, let dy, let unit):
            if let target {
                return await pointer(target) { MacInputPlanner.scroll(at: $0, dx: dx, dy: dy, unit: unit) }
            }
            guard let delivery = await keyboardDelivery() else { return noWorkingApp() }
            return await deliver(MacInputPlanner.scroll(at: await input.currentPoint, dx: dx, dy: dy, unit: unit), delivery: delivery, evidence: "scroll posted")
        case .type(let text, let into, let mode):
            return await type(text, into: into, mode: mode)
        case .key(let combo, let repeatCount):
            guard let plan = MacInputPlanner.key(combo, repeatCount: repeatCount) else { return refused("\(combo) has no key code") }
            guard let delivery = await keyboardDelivery() else { return noWorkingApp() }
            return await deliver(plan, delivery: delivery, evidence: "\(combo) posted")
        case .hold(let combo, let milliseconds):
            guard let plan = MacInputPlanner.hold(combo, milliseconds: milliseconds) else { return refused("\(combo) has no key code") }
            guard let delivery = await keyboardDelivery() else { return noWorkingApp() }
            return await deliver(plan, delivery: delivery, evidence: "\(combo) held \(milliseconds) ms")
        case .setValue(let target, let value):
            guard case .ref(let ref, let observation) = target else { return refused("set-value needs an element ref") }
            return semantic(await accessibility.setValue(ref: ref, observation: observation, value: value))
        case .menu(let path, let bundleID):
            let app: MacRunningApp
            if let bundleID {
                guard let running = await MacAppControl.runningApps(bundleIDs: [bundleID]).first else { return refused("the app is not running") }
                app = running
            } else {
                guard let working = await workingApp() else { return noWorkingApp() }
                app = working
            }
            return semantic(await accessibility.selectMenu(pid: app.pid, path: path))
        case .launch(let bundleID, let background):
            do {
                let app = try await MacAppControl.launch(bundleID: bundleID, background: background)
                return ActionOutcome(action: 0, effect: app == nil ? .unverifiable : .confirmed, evidence: "launched \(bundleID)")
            } catch {
                return refused("could not launch \(bundleID): \(error)")
            }
        case .openURL(let raw):
            guard let url = URL(string: raw) else { return refused("not a URL") }
            guard let browser = MacAppFocus.browser(granted: grantedBundleIDs, await workspace.browsers()) else {
                return refused("no granted app opens web pages; the run needs a browser granted to open \(url.host() ?? raw)")
            }
            do {
                try await MacAppControl.open(url, inApp: browser)
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "opened in \(browser)")
            } catch {
                return refused("could not open the URL: \(error)")
            }
        }
    }

    private func type(_ text: String, into target: ActionTarget?, mode: TypeMode?) async -> ActionOutcome {
        if case .ref(let ref, let observation)? = target {
            if mode == .setValue {
                return semantic(await accessibility.setValue(ref: ref, observation: observation, value: text))
            }
            if case .refused(let reason) = await accessibility.focus(ref: ref, observation: observation) {
                return refused(reason, escalation: .observe)
            }
        }
        guard let delivery = await keyboardDelivery() else { return noWorkingApp() }
        if mode == .paste {
            return await paste(text, delivery: delivery)
        }
        return await deliver(MacInputPlanner.type(text), delivery: delivery, evidence: "typed \(text.count) characters")
    }

    /// Save the clipboard, write, paste, and restore it.
    private func paste(_ text: String, delivery: MacInputDelivery) async -> ActionOutcome {
        let saved = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let written = await MainActor.run { NSPasteboard.general.string(forType: .string) == text }
        guard written, let plan = MacInputPlanner.key(KeyCombo(modifiers: [.cmd], key: "v"), repeatCount: 1) else {
            return refused("the clipboard write did not verify")
        }
        await input.post(plan, delivery: delivery)
        try? await Task.sleep(for: .milliseconds(150))
        await MainActor.run {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        return ActionOutcome(action: 0, effect: .unverifiable, evidence: "pasted \(text.count) characters; clipboard restored")
    }

    // MARK: - Targets and delivery

    private struct ResolvedPoint {
        var point: CGPoint
        var delivery: MacInputDelivery
    }

    private struct Refusal: Error {
        var message: String
    }

    private func pointer(_ target: ActionTarget, plan: (CGPoint) -> [MacInputEvent]) async -> ActionOutcome {
        switch await resolvePoint(target) {
        case .success(let resolved):
            return await deliver(plan(resolved.point), delivery: resolved.delivery, evidence: "events posted")
        case .failure(let refusal):
            return refused(refusal.message, escalation: .observe)
        }
    }

    /// Posts `events`. A background delivery into an app is checked for any change in its window; when there is
    /// none and the lease allows the foreground, later actions in that app go to the foreground. The action itself
    /// is never delivered again, since it may have landed.
    private func deliver(_ events: [MacInputEvent], delivery: MacInputDelivery, evidence: String) async -> ActionOutcome {
        let described = "\(evidence) (\(Self.describe(delivery)))"
        guard foregroundAllowed, case .process(let pid) = delivery, let app = await workspace.runningApp(pid: pid) else {
            await input.post(events, delivery: delivery)
            return ActionOutcome(action: 0, effect: .unverifiable, evidence: described)
        }
        let probe = probe
        let before = await probe.state(of: pid, app: app.identity)
        await input.post(events, delivery: delivery)
        guard let before else { return ActionOutcome(action: 0, effect: .unverifiable, evidence: described) }
        try? await Task.sleep(for: Self.deliverySettle)
        guard await probe.state(of: pid, app: app.identity) == before else {
            return ActionOutcome(action: 0, effect: .unverifiable, evidence: described)
        }
        foregroundApps.insert(pid)
        return ActionOutcome(
            action: 0,
            effect: .suspectedNoop,
            evidence: "\(described); nothing changed in \(app.identity.bundleID)'s window, so its later actions go to the foreground",
            escalation: .foreground
        )
    }

    static let deliverySettle: Duration = .milliseconds(150)

    /// Resolves a target to a point, checking the process generation and, for refs, element drift.
    private func resolvePoint(_ target: ActionTarget) async -> Result<ResolvedPoint, Refusal> {
        guard let meta = observations[target.observation] else {
            return .failure(Refusal(message: "observation \(target.observation) was not made by this target or is no longer retained"))
        }
        let point: CGPoint
        switch target {
        case .point(let global, _):
            point = MacCoordinateSpace.cgPoint(global)
        case .ref(let ref, let observation):
            switch await accessibility.resolve(ref: ref, observation: observation) {
            case .refused(let reason): return .failure(Refusal(message: reason))
            case .resolved(let frame):
                guard let frame else { return .failure(Refusal(message: "element \(ref) has no frame")) }
                point = CGPoint(x: frame.midX, y: frame.midY)
            }
        }
        guard let pid = meta.pid else {
            return .failure(Refusal(message: "the observation is not pinned to a granted app"))
        }
        guard let running = await workspace.runningApp(pid: pid), running.launchDate == meta.processStart else {
            return .failure(Refusal(message: "the app from observation \(target.observation) has quit or restarted"))
        }
        guard MacAppFocus.point(point, landsOn: pid, windows: await workspace.windows(), ignoring: getpid()) else {
            return .failure(Refusal(message: "(\(Int(point.x)), \(Int(point.y))) is not over a window of \(running.identity.bundleID)"))
        }
        cited = (pid, meta.processStart)
        let delivery = await delivery(for: pid)
        if delivery == .foreground {
            // A foreground event lands on whatever window is on top at the point.
            let owner = MacAppFocus.topmostOwner(at: point, windows: await workspace.windows(), ignoring: getpid())
            if owner != pid {
                var name: String?
                if let owner { name = await workspace.runningApp(pid: owner)?.identity.bundleID }
                guard let name, grantedBundleIDs.contains(name) else {
                    return .failure(Refusal(message: "(\(Int(point.x)), \(Int(point.y))) is covered by \(name ?? "a window") that isn't granted"))
                }
            }
        }
        return .success(ResolvedPoint(point: point, delivery: delivery))
    }

    /// Background-first: events go to the target process. Foreground delivery is a consented escalation, used for
    /// app classes background events are known to fail in and for apps where a background action changed nothing;
    /// it activates the app and is undone on release.
    private func delivery(for pid: pid_t) async -> MacInputDelivery {
        guard foregroundAllowed else { return .process(pid) }
        let app = await workspace.runningApp(pid: pid)
        let upFront = app.map { MacForegroundPolicy.upFront($0.identity, for: currentAction) } ?? false
        guard upFront || foregroundApps.contains(pid) else { return .process(pid) }
        let frontmost = await workspace.frontmostApp()?.pid
        if frontmost != pid, let frontmost {
            if restoreFrontmost == nil { restoreFrontmost = (frontmost, pid) }
            _ = await MacAppControl.activate(pid: pid)
            await configuration.onForegroundDelivery?(app?.identity.bundleID)
        }
        return .foreground
    }

    /// Delivery for input that names no target: to the working app, never to whatever happens to be in front.
    private func keyboardDelivery() async -> MacInputDelivery? {
        guard let app = await workingApp() else { return nil }
        return await delivery(for: app.pid)
    }

    /// The app target-less input and full-screen observations belong to: the app of the most recently cited
    /// observation. Before anything is cited, the frontmost app when it is granted, else the granted app with the
    /// frontmost window, since the harness's own app is usually in front.
    private func workingApp() async -> MacRunningApp? {
        let granted = grantedBundleIDs
        if let cited, let app = await workspace.runningApp(pid: cited.pid), app.launchDate == cited.start,
           granted.contains(app.identity.bundleID) {
            return app
        }
        if let frontmost = await workspace.frontmostApp(), granted.contains(frontmost.identity.bundleID) { return frontmost }
        for pid in MacAppFocus.appsByWindowOrder(await workspace.windows()) {
            if let app = await workspace.runningApp(pid: pid), granted.contains(app.identity.bundleID) { return app }
        }
        return nil
    }

    private func noWorkingApp() -> ActionOutcome {
        refused("no granted app is on screen to receive input; launch one or observe again", escalation: .observe)
    }

    private var grantedBundleIDs: Set<String> {
        Set(grants.grants.compactMap { grant in
            if case .app(let bundleID, _, _) = grant { return bundleID }
            return nil
        }).subtracting(configuration.excludedBundleIDs)
    }

    /// Stands in for an observation of the app `pid`, for tests that act without capturing the screen.
    func seedObservation(_ id: ObservationID, pid: pid_t, processStart: Date?) {
        retain(ObservationMeta(pid: pid, processStart: processStart), for: id)
    }

    private func retain(_ meta: ObservationMeta, for id: ObservationID) {
        observations[id] = meta
        observationOrder.append(id)
        while observationOrder.count > 8 {
            observations.removeValue(forKey: observationOrder.removeFirst())
        }
    }

    private func requireLease(_ lease: Lease) async throws {
        guard await lock.holds(leaseID: lease.id) else { throw DisplayTargetError.leaseNotHeld }
    }

    private func semantic(_ result: MacAccessibilityReader.SemanticResult) -> ActionOutcome {
        switch result {
        case .performed(let evidence):
            return ActionOutcome(action: 0, effect: evidence == "value read back" ? .confirmed : .unverifiable, evidence: evidence)
        case .unverifiable(let evidence):
            return ActionOutcome(action: 0, effect: .unverifiable, evidence: evidence, escalation: .observe)
        case .unsupported(let reason):
            return refused(reason)
        case .refused(let reason):
            return refused(reason, escalation: .observe)
        }
    }

    private func refused(_ reason: String, escalation: ActionEscalation? = nil) -> ActionOutcome {
        ActionOutcome(action: 0, effect: .refused, evidence: reason, escalation: escalation)
    }

    private static func describe(_ delivery: MacInputDelivery) -> String {
        switch delivery {
        case .process(let pid): return "to process \(pid)"
        case .foreground: return "foreground"
        }
    }
}
#endif
