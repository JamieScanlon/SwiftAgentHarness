import Foundation
@testable import SwiftAgentHarness

/// A scripted display target. Observations get sequential ids; actions are recorded and answered by `outcomes`.
actor FakeDisplayTarget: DisplayTarget {
    static let hostManifest = DisplayTargetManifest(
        id: "fake-host",
        label: "Fake host desktop",
        platform: "macos",
        isolation: .host,
        perception: [.pixels, .accessibility],
        delivery: [.background, .foreground],
        semanticActions: [.press, .setValue, .menuPath, .launchApp, .openURL],
        requires: [.screenCapture, .accessibility, .postEvents],
        humanPresence: .shared
    )

    static let vmManifest = DisplayTargetManifest(
        id: "fake-vm",
        label: "Fake VM",
        platform: "linux",
        isolation: .vm,
        perception: [.pixels, .accessibility],
        delivery: [.background],
        observerAccess: .vnc,
        humanPresence: .none
    )

    nonisolated let manifest: DisplayTargetManifest
    private let lock = DisplayTargetLeaseLock()
    private var permissionStates: [DisplayPlatformPermission: PermissionState]
    private let now: @Sendable () -> Date
    private var observationCounter = 0

    var observedApp: AppIdentity = ComputerUseFixtures.textEdit
    var observedURL: String?
    var outcomes: @Sendable (ComputerAction, Int) -> ActionOutcome = { _, index in
        ActionOutcome(action: index, effect: .confirmed, evidence: "fake")
    }
    private(set) var actCalls: [[ComputerAction]] = []
    private(set) var observeCalls: [ObserveRequest] = []
    private(set) var releases: [ReleaseReason] = []
    private(set) var takeoverStates: [Bool] = []

    init(
        manifest: DisplayTargetManifest,
        permissions: [DisplayPlatformPermission: PermissionState]? = nil,
        now: @escaping @Sendable () -> Date = { ComputerUseFixtures.epoch }
    ) {
        self.manifest = manifest
        self.permissionStates = permissions
            ?? Dictionary(uniqueKeysWithValues: manifest.requires.map { ($0, PermissionState.granted) })
        self.now = now
    }

    func setPermission(_ permission: DisplayPlatformPermission, _ state: PermissionState) {
        permissionStates[permission] = state
    }

    func setObserved(app: AppIdentity, url: String? = nil) {
        observedApp = app
        observedURL = url
    }

    func setOutcomes(_ outcomes: @escaping @Sendable (ComputerAction, Int) -> ActionOutcome) {
        self.outcomes = outcomes
    }

    func lease(_ request: LeaseRequest) async throws -> Lease {
        let lease = Lease(request: request, issuedAt: now())
        try await lock.acquire(leaseID: lease.id, holder: .init(id: request.agentID, isAlive: request.isHolderAlive))
        return lease
    }

    func release(_ lease: Lease, reason: ReleaseReason) async {
        if await lock.release(leaseID: lease.id) {
            releases.append(reason)
        }
    }

    func permissions() async -> PermissionSnapshot {
        PermissionSnapshot(states: permissionStates)
    }

    func describe(_ lease: Lease) async throws -> TargetLayout {
        try await requireLease(lease)
        return TargetLayout(
            displays: [DisplayInfo(id: "main", frame: ComputerUseFixtures.geometry.capturedRect, scaleFactor: 2, isPrimary: true)],
            focusedApp: observedApp
        )
    }

    func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        try await requireLease(lease)
        observeCalls.append(request)
        observationCounter += 1
        return ComputerUseFixtures.observation(
            id: "o_\(observationCounter)",
            app: observedApp,
            url: observedURL,
            at: now(),
            withImage: request.modes.contains(.pixels)
        )
    }

    func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        try await requireLease(lease)
        actCalls.append(batch.actions)
        var results: [ActionOutcome] = []
        for (index, action) in batch.actions.enumerated() {
            let outcome = outcomes(action, index)
            results.append(outcome)
            if outcome.effect.stopsBatch { break }
        }
        return results
    }

    func takeover(_ lease: Lease, on: Bool) async throws {
        try await requireLease(lease)
        takeoverStates.append(on)
    }

    private func requireLease(_ lease: Lease) async throws {
        guard await lock.holds(leaseID: lease.id) else { throw DisplayTargetError.leaseNotHeld }
    }
}

enum ComputerUseFixtures {
    static let textEdit = AppIdentity(bundleID: "com.apple.TextEdit", category: "public.app-category.productivity")
    static let terminal = AppIdentity(bundleID: "com.apple.Terminal", category: "public.app-category.developer-tools")
    static let safari = AppIdentity(bundleID: "com.apple.Safari", category: "public.app-category.productivity")
    static let systemSettings = AppIdentity(bundleID: "com.apple.systempreferences", category: "public.app-category.utilities")
    static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    static let geometry = ScreenshotGeometry(
        capturedRect: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
        imageSize: ImagePixelSize(width: 1280, height: 800),
        scaleFactor: 2
    )

    static func elements(app: AppIdentity = textEdit, url: String? = nil) -> [String: ElementRef] {
        [
            "e1": ElementRef(id: "e1", role: "AXToolbar", app: app, url: url),
            "e2": ElementRef(id: "e2", role: "AXButton", label: "Bold", frame: DisplayRect(x: 10, y: 10, width: 30, height: 20), app: app, url: url),
            "e5": ElementRef(id: "e5", role: "AXTextArea", frame: DisplayRect(x: 0, y: 60, width: 1440, height: 800), app: app, url: url),
            "e6": ElementRef(id: "e6", role: "AXButton", label: "Save", frame: DisplayRect(x: 1300, y: 860, width: 80, height: 24), app: app, url: url),
            "e7": ElementRef(id: "e7", role: "AXSecureTextField", label: "Password", app: app, url: url, isSecureInput: true),
            "e8": ElementRef(id: "e8", role: "AXButton", label: "Delete account", app: app, url: url),
            "e9": ElementRef(id: "e9", role: "textbox", app: app, url: url, inputPurpose: "cc-number"),
        ]
    }

    static func observation(
        id: ObservationID,
        app: AppIdentity = textEdit,
        url: String? = nil,
        at: Date = epoch,
        withImage: Bool = true
    ) -> DisplayObservation {
        DisplayObservation(
            id: id,
            at: at,
            target: ObservationTarget(
                app: app,
                pid: 4242,
                processStart: epoch.addingTimeInterval(-3600),
                windowID: "w1",
                url: url,
                bounds: geometry.capturedRect
            ),
            image: withImage
                ? ObservationImage(blobRef: "blob:\(id)", data: ToolImageFixtures.tinyPNG, geometry: geometry, capturedAt: at)
                : nil,
            tree: ObservationTree(
                text: "window app=\(app.bundleID) obs=\(id)\n[e2] button \"Bold\"\n[e5] textarea\n[e6] button \"Save\"",
                elements: elements(app: app, url: url),
                capturedAt: at.addingTimeInterval(0.05)
            )
        )
    }
}
