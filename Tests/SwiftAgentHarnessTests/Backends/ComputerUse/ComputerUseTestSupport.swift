import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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
    /// Replaces the fixture's tiny PNG in observations, for tests that read pixels.
    var screenshot: Data?
    /// Trees for successive observations, in place of the fixture's.
    var trees: [ObservationTree] = []
    var outcomes: @Sendable (ComputerAction, Int) -> ActionOutcome = { _, index in
        ActionOutcome(action: index, effect: .confirmed, evidence: "fake")
    }
    private(set) var actCalls: [[ComputerAction]] = []
    private(set) var observeCalls: [ObserveRequest] = []
    private(set) var releases: [ReleaseReason] = []
    private(set) var takeoverStates: [Bool] = []
    /// Like a remote target, work requested from a cancelled task never reaches the screen.
    private(set) var failsWhenCancelled = false

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

    func setFailsWhenCancelled(_ fails: Bool) {
        failsWhenCancelled = fails
    }

    func setPermission(_ permission: DisplayPlatformPermission, _ state: PermissionState) {
        permissionStates[permission] = state
    }

    func setObserved(app: AppIdentity, url: String? = nil) {
        observedApp = app
        observedURL = url
    }

    func setScreenshot(_ data: Data?) {
        screenshot = data
    }

    func setTrees(_ trees: [ObservationTree]) {
        self.trees = trees
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
        if failsWhenCancelled, Task.isCancelled { return }
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
        var observation = ComputerUseFixtures.observation(
            id: "o_\(observationCounter)",
            app: observedApp,
            url: observedURL,
            at: now(),
            withImage: request.modes.contains(.pixels)
        )
        if let screenshot { observation.image?.data = screenshot }
        if request.modes.contains(.accessibility), observationCounter <= trees.count {
            observation.tree = trees[observationCounter - 1]
        }
        return observation
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
        if failsWhenCancelled { try Task.checkCancellation() }
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

extension ComputerUseFixtures {
    /// An installation with the oversight coordinator wired to `publisher`.
    static func installation(publisher: RecordingIntentPublisher) -> ComputerUseInstallation {
        let installation = ComputerUseInstallation()
        installation.install(
            ComputerUseConfiguration(
                registry: DisplayTargetRegistry(targets: []),
                defaults: ComputerUseSpecialistDefaults(
                    target: FakeDisplayTarget.hostManifest.id,
                    budgets: ComputerUseBudgetPolicy(defaultSteps: 12, ceilingSteps: 12, maxDuration: .seconds(600))
                ),
                approveGrants: { _ in nil }
            ),
            publish: { await publisher.publish($0, $1) }
        )
        return installation
    }

    /// Registers a live specialist session working for `parent`, as delegate dispatch would.
    @discardableResult
    static func registerLiveSession(
        in installation: ComputerUseInstallation,
        parent: UUID,
        lifecycleID: String
    ) async throws -> (ComputerUseSession, FakeDisplayTarget) {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest, now: { Date() })
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "computer-use:\(lifecycleID)",
            grants: [.app(bundleID: textEdit.bundleID, tier: .full)],
            budgets: ComputerUseBudgets(steps: 12, maxDuration: .seconds(600)),
            operatorInitiated: true,
            userPresent: true
        ))
        let session = ComputerUseSession(
            target: target,
            lease: lease,
            configuration: ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["Save the file."]))
        )
        await installation.sessions.register(
            ComputerUseSessionEntry(session: session, parentConversationID: parent, lifecycleID: lifecycleID, targetLabel: target.manifest.label),
            for: UUID()
        )
        return (session, target)
    }

    /// Starts a question from `lifecycleID` and waits until it is pending.
    static func pendingQuestion(
        _ question: String,
        coordinator: ComputerUseOversightCoordinator,
        conversationID: UUID,
        lifecycleID: String
    ) async throws -> (ComputerUsePendingRequest, Task<ComputerUseRequestResolution, Never>) {
        let asking = Task {
            await coordinator.ask(conversationID: conversationID, lifecycleID: lifecycleID, target: FakeDisplayTarget.hostManifest.label, question: question)
        }
        for _ in 0..<500 {
            if let request = await coordinator.pending(conversationID: conversationID).first(where: { $0.prompt == question }) {
                return (request, asking)
            }
            await Task.yield()
        }
        asking.cancel()
        throw CancellationError()
    }
}

extension ComputerUseFixtures {
    /// A real PNG sized as ``geometry`` says (1280×800 for a 1440×900 pt capture).
    static func pngScreenshot(width: Int = 1280, height: Int = 800) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.featureUnsupported) }
        return data as Data
    }
}
