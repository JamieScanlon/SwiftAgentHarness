import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

public struct AndroidDeviceConfiguration: Sendable {
    public var id: DisplayTargetID
    public var label: String
    /// The device's serial, as `adb devices` lists it. `nil` uses the only device connected.
    public var serial: String?
    public var adb: String
    /// Whether a person may be using the device. A paired phone is someone's, so it is `shared` by default.
    public var humanPresence: DisplayHumanPresence
    public var settleDelay: Duration
    public var retainedObservations: Int

    public init(
        id: DisplayTargetID = "android-device",
        label: String = "Android device",
        serial: String? = nil,
        adb: String = "adb",
        humanPresence: DisplayHumanPresence = .shared,
        settleDelay: Duration = .milliseconds(300),
        retainedObservations: Int = 8
    ) {
        self.id = id
        self.label = label
        self.serial = serial
        self.adb = adb
        self.humanPresence = humanPresence
        self.settleDelay = settleDelay
        self.retainedObservations = max(1, retainedObservations)
    }
}

/// A paired Android device driven over `adb`: screenshots with `screencap`, the accessibility tree with
/// `uiautomator`, and input with `input`. Coordinates are the screen's pixels. Refs are matched against a fresh
/// tree before each action, and points are refused once the focused activity changed since their observation.
public actor AndroidDisplayTarget: DisplayTarget {
    public nonisolated let manifest: DisplayTargetManifest
    public nonisolated let configuration: AndroidDeviceConfiguration
    private let runner: any DisplayCommandRunner
    private let lock = DisplayTargetLeaseLock()
    private var leased = false
    private var screen = ImagePixelSize(width: 0, height: 0)
    private var takeoverActive = false
    private var observationCounter = 0
    private var observed: [ObservationID: Snapshot] = [:]
    private var observationOrder: [ObservationID] = []

    struct Node: Equatable {
        var className: String
        var resourceID: String
        var label: String
        var package: String
        var bounds: DisplayRect
        var clickable: Bool
        var focused: Bool
        var password: Bool
        var depth: Int

        var role: String { className.split(separator: ".").last.map(String.init) ?? className }
        var center: DisplayPoint { DisplayPoint(x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2) }
    }

    struct Snapshot {
        var activity: String
        var nodes: [String: Node]
    }

    #if os(macOS) || os(Linux)
    public init(configuration: AndroidDeviceConfiguration = AndroidDeviceConfiguration()) {
        self.init(configuration: configuration, runner: LocalDisplayCommandRunner())
    }
    #endif

    public init(configuration: AndroidDeviceConfiguration, runner: any DisplayCommandRunner) {
        self.configuration = configuration
        self.runner = runner
        manifest = DisplayTargetManifest(
            id: configuration.id,
            label: configuration.label,
            platform: "android",
            isolation: .remoteDevice,
            perception: [.pixels, .accessibility],
            delivery: [.background],
            semanticActions: [.press, .launchApp, .openURL],
            humanPresence: configuration.humanPresence
        )
    }

    // MARK: - Lifecycle

    public func lease(_ request: LeaseRequest) async throws -> Lease {
        let lease = Lease(request: request, issuedAt: Date())
        try await lock.acquire(leaseID: lease.id, holder: DisplayTargetLeaseLock.Holder(id: request.agentID, isAlive: request.isHolderAlive))
        do {
            let state = try await adb(["get-state"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state == "device" else { throw DisplayTargetError.driverFailure("the device is \(state.isEmpty ? "not connected" : state)") }
            screen = try Self.screenSize(try await shell("wm size").text)
        } catch {
            await lock.release(leaseID: lease.id)
            throw error is DisplayTargetError ? error : DisplayTargetError.driverFailure("the device is unreachable: \(error)")
        }
        leased = true
        takeoverActive = false
        observationCounter = 0
        observed = [:]
        observationOrder = []
        return lease
    }

    public func release(_ lease: Lease, reason: ReleaseReason) async {
        guard await lock.holds(leaseID: lease.id) else { return }
        leased = false
        takeoverActive = false
        await lock.release(leaseID: lease.id)
    }

    public func permissions() async -> PermissionSnapshot {
        PermissionSnapshot(states: [:])
    }

    public func describe(_ lease: Lease) async throws -> TargetLayout {
        try await requireLease(lease)
        let focus = try await focusedActivity()
        return TargetLayout(
            displays: [DisplayInfo(id: "screen", frame: screenRect, scaleFactor: 1, isPrimary: true)],
            focusedApp: Self.package(of: focus).map { AppIdentity(bundleID: $0) }
        )
    }

    /// The user holds the device, so takeover only pauses the agent.
    public func takeover(_ lease: Lease, on: Bool) async throws {
        try await requireLease(lease)
        takeoverActive = on
    }

    private var screenRect: DisplayRect {
        DisplayRect(x: 0, y: 0, width: Double(screen.width), height: Double(screen.height))
    }

    // MARK: - Perception

    public func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        try await requireLease(lease)
        guard !takeoverActive else { throw DisplayTargetError.unsupported("the user has taken over; capture is paused") }
        observationCounter += 1
        let id: ObservationID = "o_\(observationCounter)"
        let activity = try await focusedActivity()
        let package = Self.package(of: activity)

        var tree: ObservationTree?
        var nodes: [String: Node] = [:]
        if request.modes.contains(.accessibility) {
            let dumped = try await uiTree()
            let treeAt = Date()
            nodes = Dictionary(uniqueKeysWithValues: dumped.enumerated().map { ("e\($0.offset + 1)", $0.element) })
            tree = ObservationTree(
                text: Self.render(dumped, observationID: id, activity: activity),
                elements: Dictionary(uniqueKeysWithValues: nodes.map { ref, node in
                    (ref, ElementRef(
                        id: ref, role: node.role, label: node.label.isEmpty ? nil : node.label, frame: node.bounds,
                        app: AppIdentity(bundleID: node.package), isSecureInput: node.password, depth: node.depth, isFocused: node.focused
                    ))
                }),
                capturedAt: treeAt
            )
        }

        var image: ObservationImage?
        if request.modes.contains(.pixels) {
            image = try await screenshot(id: id, scope: request.scope, limit: request.maxImage)
        }
        observed[id] = Snapshot(activity: activity, nodes: nodes)
        observationOrder.append(id)
        while observationOrder.count > configuration.retainedObservations {
            observed[observationOrder.removeFirst()] = nil
        }
        return DisplayObservation(
            id: id,
            at: Date(),
            target: ObservationTarget(app: package.map { AppIdentity(bundleID: $0) }, windowID: activity.isEmpty ? nil : activity, bounds: screenRect),
            image: image,
            tree: tree
        )
    }

    private func screenshot(id: ObservationID, scope: ObservationScope, limit: ObservationImageLimit?) async throws -> ObservationImage {
        let png = try await adb(["exec-out", "screencap", "-p"], timeout: .seconds(20)).stdout
        guard let full = ManagedBrowserDisplayTarget.pngSize(png) else { throw DisplayTargetError.driverFailure("the screenshot was empty") }
        var captured = DisplayRect(x: 0, y: 0, width: Double(full.width), height: Double(full.height))
        if case .region(let region) = scope {
            captured = DisplayRect(
                x: max(0, region.minX).rounded(.down),
                y: max(0, region.minY).rounded(.down),
                width: (min(Double(full.width), region.maxX) - max(0, region.minX)).rounded(.up),
                height: (min(Double(full.height), region.maxY) - max(0, region.minY)).rounded(.up)
            )
            guard captured.width >= 1, captured.height >= 1 else { throw DisplayTargetError.unsupported("the region lies outside the screen") }
        }
        let isZoom = if case .region = scope { true } else { false }
        let scale = ManagedBrowserDisplayTarget.scale(for: captured, limit: limit, zoom: isZoom)
        var size = ImagePixelSize(width: max(1, Int((captured.width * scale).rounded())), height: max(1, Int((captured.height * scale).rounded())))
        var data = png
        #if canImport(ImageIO)
        let whole = captured.width == Double(full.width) && captured.height == Double(full.height)
        if !whole || size != full {
            guard let resized = Self.resized(png, crop: captured, to: size) else { throw DisplayTargetError.driverFailure("the screenshot couldn't be decoded") }
            data = resized
        }
        #else
        size = full
        captured = DisplayRect(x: 0, y: 0, width: Double(full.width), height: Double(full.height))
        #endif
        return ObservationImage(
            blobRef: "android:\(id)",
            data: data,
            mediaType: "image/png",
            geometry: ScreenshotGeometry(capturedRect: captured, imageSize: ManagedBrowserDisplayTarget.pngSize(data) ?? size, scaleFactor: 1),
            capturedAt: Date()
        )
    }

    #if canImport(ImageIO)
    static func resized(_ png: Data, crop: DisplayRect, to size: ImagePixelSize) -> Data? {
        guard var image = ComputerUseImageEncoding.decode(png) else { return nil }
        if crop.width < Double(image.width) || crop.height < Double(image.height) {
            guard let cropped = image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)) else { return nil }
            image = cropped
        }
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage().flatMap { ComputerUseImageEncoding.encode($0, as: .png) }
    }
    #endif

    /// `package/activity` of the focused window, or empty.
    func focusedActivity() async throws -> String {
        let text = try await shell("dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'").text
        return Self.focusedActivity(text)
    }

    static func focusedActivity(_ dumpsys: String) -> String {
        for line in dumpsys.split(whereSeparator: \.isNewline) where line.contains("mCurrentFocus") || line.contains("mFocusedApp") {
            if let match = line.firstMatch(of: /([A-Za-z][\w.]*\/[\w.$]+)/) { return String(match.1) }
        }
        return ""
    }

    static func package(of activity: String) -> String? {
        activity.split(separator: "/").first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    func uiTree() async throws -> [Node] {
        let dump = try await adb(["exec-out", "uiautomator", "dump", "/dev/tty"], timeout: .seconds(20)).text
        return Self.parse(dump)
    }

    /// The tree's elements worth acting on or reading: clickable, focusable, or labeled.
    static func parse(_ dump: String) -> [Node] {
        guard let start = dump.range(of: "<hierarchy"), let end = dump.range(of: "</hierarchy>", options: .backwards) else { return [] }
        let xml = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + dump[start.lowerBound..<end.upperBound]).utf8)
        let delegate = UIHierarchyParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.nodes
    }

    static func render(_ nodes: [Node], observationID: ObservationID, activity: String) -> String {
        var lines = ["screen activity=\(activity.isEmpty ? "unknown" : activity) obs=\(observationID)"]
        for (index, node) in nodes.enumerated() {
            var line = String(repeating: "  ", count: min(node.depth, 12)) + "[e\(index + 1)] \(node.role)"
            if !node.label.isEmpty { line += " \"\(singleLine(String(node.label.prefix(120))))\"" }
            if !node.resourceID.isEmpty { line += " id=\(node.resourceID)" }
            if node.password { line += " (password)" }
            if node.focused { line += " (focused)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
    }

    static func screenSize(_ text: String) throws -> ImagePixelSize {
        var size: ImagePixelSize?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: /(\d+)x(\d+)/), let width = Int(match.1), let height = Int(match.2) else { continue }
            if size == nil || line.contains("Override") { size = ImagePixelSize(width: width, height: height) }
        }
        guard let size, size.width > 0, size.height > 0 else { throw DisplayTargetError.driverFailure("the device reported no screen size") }
        return size
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
                guard modifiers.isEmpty else { return refused("a touch screen has no modifier keys") }
                let point = try await resolve(at)
                if button == .right {
                    try await input(["swipe", Self.int(point.x), Self.int(point.y), Self.int(point.x), Self.int(point.y), "600"])
                    try await settle()
                    return ActionOutcome(action: 0, effect: .unverifiable, evidence: "long-pressed at (\(Int(point.x)), \(Int(point.y)))")
                }
                for _ in 0..<max(1, min(count, 3)) { try await input(["tap", Self.int(point.x), Self.int(point.y)]) }
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "tapped at (\(Int(point.x)), \(Int(point.y)))")
            case .press(let at):
                let point = try await resolve(at)
                try await input(["tap", Self.int(point.x), Self.int(point.y)])
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "\(at.elementRef ?? "element") tapped")
            case .drag(let path, let modifiers):
                guard modifiers.isEmpty else { return refused("a touch screen has no modifier keys") }
                guard path.count == 2 else { return refused("the device drags in a straight line; give two points") }
                let from = try await resolve(path[0])
                let to = try await resolve(path[1])
                try await input(["swipe", Self.int(from.x), Self.int(from.y), Self.int(to.x), Self.int(to.y), "500"])
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "swiped")
            case .scroll(let at, let dx, let dy, let unit):
                var origin = DisplayPoint(x: Double(screen.width) / 2, y: Double(screen.height) / 2)
                if let at { origin = try await resolve(at) }
                let factor = unit == .line ? Double(screen.height) / 20 : 1
                // Content moves with the finger, so scrolling down swipes up.
                let to = DisplayPoint(
                    x: min(max(origin.x - dx * factor, 0), Double(screen.width - 1)),
                    y: min(max(origin.y - dy * factor, 0), Double(screen.height - 1))
                )
                try await input(["swipe", Self.int(origin.x), Self.int(origin.y), Self.int(to.x), Self.int(to.y), "300"])
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "scrolled")
            case .type(let text, let into, let mode):
                guard mode != .setValue else { return refused("the device can't set a field's value directly; type into it instead") }
                guard text.unicodeScalars.allSatisfy({ $0.isASCII && ($0.value >= 0x20 || $0 == "\n") }) else {
                    return refused("adb types only printable ASCII; ask the user to enter this text")
                }
                if let into {
                    let point = try await resolve(into)
                    try await input(["tap", Self.int(point.x), Self.int(point.y)])
                }
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if index > 0 { try await input(["keyevent", "66"]) }
                    for chunk in Self.chunks(String(line), size: 100) {
                        try await input(["text", chunk.replacingOccurrences(of: " ", with: "%s")])
                    }
                }
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "typed \(text.count) characters")
            case .key(let combo, let repeatCount):
                guard combo.modifiers.isEmpty, let code = Self.keyCodes[combo.key] ?? Self.characterKeyCode(combo.key) else {
                    return refused("\(combo) names no key on the device")
                }
                for _ in 0..<max(1, min(repeatCount, 50)) { try await input(["keyevent", String(code)]) }
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "\(combo) sent")
            case .launch(let app, _):
                guard app.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil else {
                    return refused("\(app) isn't a package name")
                }
                let output = try await shell("monkey -p \(app) -c android.intent.category.LAUNCHER 1").text
                if output.contains("No activities found") { return refused("\(app) isn't installed") }
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "started \(app)")
            case .openURL(let url):
                let output = try await shell("am start -a android.intent.action.VIEW -d \(SSHDisplayCommandRunner.quote(url))").text
                if output.contains("Error") { return ActionOutcome(action: 0, effect: .partial, evidence: "the device couldn't open the URL", escalation: .observe) }
                try await settle()
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "asked the device to open the URL")
            case .wait(let milliseconds):
                try? await Task.sleep(for: .milliseconds(max(0, min(milliseconds, 60_000))))
                return ActionOutcome(action: 0, effect: .confirmed, evidence: "waited \(milliseconds) ms")
            case .waitFor:
                return ActionOutcome(action: 0, effect: .unverifiable, evidence: "the driver does not evaluate conditions; observe to check", escalation: .observe)
            case .move, .pointer, .hold:
                return refused("a touch screen has no pointer to move or hold")
            case .setValue:
                return refused("the device can't set a field's value directly; type into it instead")
            case .menu:
                return refused("the device has no menu bar; tap the app's own menu instead")
            case .observe, .zoom:
                return refused("observe through the session, not as a driver action")
            case .script:
                return refused("this target runs no scripts")
            }
        } catch let refusal as Refusal {
            return refusal.outcome
        } catch {
            return ActionOutcome(action: 0, effect: .unverifiable, evidence: "driver error: \(error)", escalation: .observe)
        }
    }

    /// A ref is looked up in a fresh tree and must still be there, the same element, within a few pixels; a point
    /// needs the same activity in front as when it was observed.
    private func resolve(_ target: ActionTarget) async throws -> DisplayPoint {
        guard let snapshot = observed[target.observation] else {
            throw Refusal(outcome: refused("observation \(target.observation) is not retained; observe again", escalation: .observe))
        }
        switch target {
        case .point(let point, _):
            guard screenRect.contains(point) else { throw Refusal(outcome: refused("the point lies outside the screen")) }
            guard try await focusedActivity() == snapshot.activity else {
                throw Refusal(outcome: refused("another screen is in front since observation \(target.observation); observe again", escalation: .observe))
            }
            return point
        case .ref(let ref, _):
            guard let node = snapshot.nodes[ref] else {
                throw Refusal(outcome: refused("\(ref) is not in observation \(target.observation)", escalation: .observe))
            }
            let current = try await uiTree().first { candidate in
                candidate.className == node.className && candidate.resourceID == node.resourceID && candidate.label == node.label
                    && abs(candidate.center.x - node.center.x) <= 24 && abs(candidate.center.y - node.center.y) <= 24
            }
            guard let current else {
                throw Refusal(outcome: refused("\(ref) is gone or moved since observation \(target.observation); observe again", escalation: .observe))
            }
            return current.center
        }
    }

    private func settle() async throws {
        try? await Task.sleep(for: configuration.settleDelay)
    }

    private func input(_ arguments: [String]) async throws {
        _ = try await shell((["input"] + arguments).map(SSHDisplayCommandRunner.quote).joined(separator: " "))
    }

    /// Runs `command` in the device's shell, which reads it as shell text.
    private func shell(_ command: String) async throws -> DisplayCommandResult {
        try await adb(["shell", command])
    }

    private func adb(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> DisplayCommandResult {
        var argv = [configuration.adb]
        if let serial = configuration.serial { argv += ["-s", serial] }
        return try await runner.output(argv + arguments, timeout: timeout)
    }

    private func requireLease(_ lease: Lease) async throws {
        guard leased, await lock.holds(leaseID: lease.id) else { throw DisplayTargetError.leaseNotHeld }
    }

    static func int(_ value: Double) -> String { String(Int(value.rounded())) }

    static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count == size {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static let keyCodes: [String: Int] = [
        "return": 66, "tab": 61, "space": 62, "delete": 67, "forward-delete": 112, "escape": 111,
        "up": 19, "down": 20, "left": 21, "right": 22, "home": 3, "back": 4, "page-up": 92, "page-down": 93,
        "move-home": 122, "move-end": 123, "menu": 82, "app-switch": 187, "volume-up": 24, "volume-down": 25,
    ]

    static func characterKeyCode(_ key: String) -> Int? {
        guard key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII else { return nil }
        switch scalar.value {
        case 0x61...0x7A: return 29 + Int(scalar.value - 0x61)
        case 0x30...0x39: return 7 + Int(scalar.value - 0x30)
        default: return nil
        }
    }
}

/// Collects `uiautomator` nodes worth listing, with their depth.
private final class UIHierarchyParser: NSObject, XMLParserDelegate {
    var nodes: [AndroidDisplayTarget.Node] = []
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard name == "node" else { return }
        defer { depth += 1 }
        guard let bounds = Self.bounds(attributes["bounds"] ?? ""), bounds.width > 0, bounds.height > 0 else { return }
        let text = attributes["text"] ?? ""
        let description = attributes["content-desc"] ?? ""
        let clickable = attributes["clickable"] == "true" || attributes["long-clickable"] == "true"
        let focusable = attributes["focusable"] == "true" || attributes["scrollable"] == "true"
        guard clickable || focusable || !text.isEmpty || !description.isEmpty else { return }
        nodes.append(AndroidDisplayTarget.Node(
            className: attributes["class"] ?? "View",
            resourceID: attributes["resource-id"] ?? "",
            label: text.isEmpty ? description : text,
            package: attributes["package"] ?? "",
            bounds: bounds,
            clickable: clickable,
            focused: attributes["focused"] == "true",
            password: attributes["password"] == "true",
            depth: depth
        ))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "node" { depth -= 1 }
    }

    static func bounds(_ text: String) -> DisplayRect? {
        guard let match = text.firstMatch(of: /\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/),
              let x1 = Double(match.1), let y1 = Double(match.2), let x2 = Double(match.3), let y2 = Double(match.4) else { return nil }
        return DisplayRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}
