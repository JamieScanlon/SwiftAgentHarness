import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Android device target")
struct AndroidDisplayTargetTests {
    static func hierarchy(buttonX: Int = 100) -> String {
        """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
        <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.app" content-desc="" clickable="false" focusable="false" focused="false" password="false" bounds="[0,0][1080,2400]">\
        <node index="0" text="Sign in" resource-id="com.example.app:id/login" class="android.widget.Button" package="com.example.app" content-desc="" clickable="true" focusable="true" focused="false" password="false" bounds="[\(buttonX),200][\(buttonX + 400),300]" />\
        <node index="1" text="" resource-id="com.example.app:id/pw" class="android.widget.EditText" package="com.example.app" content-desc="Password" clickable="true" focusable="true" focused="true" password="true" bounds="[100,400][980,500]" />\
        <node index="2" text="" resource-id="" class="android.view.View" package="com.example.app" content-desc="" clickable="false" focusable="false" focused="false" password="false" bounds="[0,600][1080,700]" />\
        </node></hierarchy>UI hierchary dumped to: /dev/tty
        """
    }

    actor FakeADB: DisplayCommandRunner {
        private(set) var commands: [[String]] = []
        var state = "device"
        var activity = "com.example.app/com.example.app.MainActivity"
        var ui = AndroidDisplayTargetTests.hierarchy()
        let screenshot: Data

        init() throws {
            screenshot = try ComputerUseFixtures.pngScreenshot(width: 1080, height: 2400)
        }

        func setState(_ value: String) { state = value }
        func setActivity(_ value: String) { activity = value }
        func setUI(_ value: String) { ui = value }

        func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
            commands.append(argv)
            let rest = Array(argv.drop { $0 != "get-state" && $0 != "shell" && $0 != "exec-out" })
            switch rest.first {
            case "get-state":
                return DisplayCommandResult(stdout: Data("\(state)\n".utf8))
            case "exec-out" where rest.dropFirst().first == "screencap":
                return DisplayCommandResult(stdout: screenshot)
            case "exec-out" where rest.dropFirst().first == "uiautomator":
                return DisplayCommandResult(stdout: Data(ui.utf8))
            case "shell":
                let command = rest.dropFirst().joined(separator: " ")
                if command == "wm size" { return DisplayCommandResult(stdout: Data("Physical size: 1080x2400\n".utf8)) }
                if command.hasPrefix("dumpsys window") {
                    return DisplayCommandResult(stdout: Data("  mCurrentFocus=Window{a1b2 u0 \(activity)}\n".utf8))
                }
                if command.contains("com.missing.app") { return DisplayCommandResult(stdout: Data("** No activities found to run, monkey aborted.".utf8)) }
                return DisplayCommandResult()
            default:
                return DisplayCommandResult()
            }
        }

        func shells(_ prefix: String) -> [String] {
            commands.compactMap { $0.last }.filter { $0.hasPrefix(prefix) }
        }
    }

    private struct Fixture {
        let adb: FakeADB
        let target: AndroidDisplayTarget
        let lease: Lease
    }

    private static func fixture() async throws -> Fixture {
        let adb = try FakeADB()
        let target = AndroidDisplayTarget(configuration: AndroidDeviceConfiguration(serial: "emulator-5554", settleDelay: .zero), runner: adb)
        let lease = try await target.lease(LeaseRequest(
            target: "android-device", agentID: "a", grants: [.app(bundleID: "com.example.app", tier: .full)],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)), operatorInitiated: true, userPresent: true
        ))
        return Fixture(adb: adb, target: target, lease: lease)
    }

    private static func observe(_ fixture: Fixture) async throws -> DisplayObservation {
        try await fixture.target.observe(fixture.lease, ObserveRequest(modes: [.pixels, .accessibility], scope: .display(nil), maxImage: ObservationImageLimit(longEdgePx: 1200)))
    }

    private static func act(_ fixture: Fixture, _ action: ComputerAction) async throws -> ActionOutcome {
        try #require(try await fixture.target.act(fixture.lease, ActionBatch([action])).first)
    }

    @Test("It declares a shared remote device with pixels and an accessibility tree")
    func manifest() throws {
        let target = AndroidDisplayTarget(configuration: AndroidDeviceConfiguration(), runner: try FakeADB())
        #expect(target.manifest.platform == "android")
        #expect(target.manifest.isolation == .remoteDevice)
        #expect(target.manifest.humanPresence == .shared)
        #expect(target.manifest.perception == [.pixels, .accessibility])
        #expect(target.manifest.semanticActions == [.press, .launchApp, .openURL])
    }

    @Test("A lease needs the device connected and reads its screen size")
    func lease() async throws {
        let fixture = try await Self.fixture()
        #expect(try await fixture.target.describe(fixture.lease).displays.first?.frame == DisplayRect(x: 0, y: 0, width: 1080, height: 2400))
        #expect(await fixture.adb.commands.first == ["adb", "-s", "emulator-5554", "get-state"])
        await fixture.target.release(fixture.lease, reason: .completed)

        let offline = try FakeADB()
        await offline.setState("unauthorized")
        let target = AndroidDisplayTarget(configuration: AndroidDeviceConfiguration(), runner: offline)
        await #expect(throws: DisplayTargetError.self) {
            try await target.lease(LeaseRequest(
                target: "android-device", agentID: "a", grants: [], budgets: ComputerUseBudgets(steps: 1, maxDuration: .seconds(60)),
                operatorInitiated: true, userPresent: true
            ))
        }
        #expect(try AndroidDisplayTarget.screenSize("Physical size: 1080x2400\nOverride size: 720x1600") == ImagePixelSize(width: 720, height: 1600))
    }

    @Test("Observations carry the focused app, the tree's actionable and labeled nodes, and a screenshot sized to the model")
    func observation() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        #expect(observation.target.app == AppIdentity(bundleID: "com.example.app"))
        #expect(observation.target.windowID == "com.example.app/com.example.app.MainActivity")
        let tree = try #require(observation.tree)
        #expect(tree.text.contains(#"[e1] Button "Sign in" id=com.example.app:id/login"#))
        #expect(tree.text.contains(#"[e2] EditText "Password" id=com.example.app:id/pw (password) (focused)"#))
        #expect(tree.elements.count == 2, "a plain container isn't listed")
        #expect(tree.elements["e2"]?.isSecureInput == true)
        #expect(tree.elements["e1"]?.frame == DisplayRect(x: 100, y: 200, width: 400, height: 100))
        let image = try #require(observation.image)
        #expect(image.geometry == ScreenshotGeometry(capturedRect: DisplayRect(x: 0, y: 0, width: 1080, height: 2400), imageSize: ImagePixelSize(width: 540, height: 1200), scaleFactor: 1))
        #expect(ManagedBrowserDisplayTarget.pngSize(image.data ?? Data()) == ImagePixelSize(width: 540, height: 1200))
    }

    @Test("A ref is tapped at its live center, and refused once it moved")
    func refs() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        let pressed = try await Self.act(fixture, .press(at: .ref("e1", observation: observation.id)))
        #expect(pressed.effect == .unverifiable)
        #expect(await fixture.adb.shells("'input'").last == "'input' 'tap' '300' '250'")

        await fixture.adb.setUI(Self.hierarchy(buttonX: 300))
        let moved = try await Self.act(fixture, .click(at: .ref("e1", observation: observation.id)))
        #expect(moved.effect == .refused)
        #expect(moved.escalation == .observe)
    }

    @Test("A point is refused once another screen is in front")
    func pointDrift() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        #expect(try await Self.act(fixture, .click(at: .point(DisplayPoint(x: 10, y: 10), observation: observation.id))).effect == .unverifiable)
        await fixture.adb.setActivity("com.android.settings/.Settings")
        let drifted = try await Self.act(fixture, .click(at: .point(DisplayPoint(x: 10, y: 10), observation: observation.id)))
        #expect(drifted.effect == .refused)
        #expect(drifted.escalation == .observe)
    }

    @Test("Typing, keys, and scrolling become input commands, each argument quoted for the device's shell")
    func input() async throws {
        let fixture = try await Self.fixture()
        _ = try await Self.act(fixture, .type(text: "it's a test\nok"))
        #expect(await fixture.adb.shells("'input'").suffix(3) == [
            #"'input' 'text' 'it'\''s%sa%stest'"#, "'input' 'keyevent' '66'", "'input' 'text' 'ok'",
        ])
        #expect(try await Self.act(fixture, .type(text: "café")).effect == .refused)
        _ = try await Self.act(fixture, .key(combo: try KeyCombo(parsing: "return")))
        #expect(await fixture.adb.shells("'input'").last == "'input' 'keyevent' '66'")
        _ = try await Self.act(fixture, .key(combo: try KeyCombo(parsing: "a")))
        #expect(await fixture.adb.shells("'input'").last == "'input' 'keyevent' '29'")
        #expect(try await Self.act(fixture, .key(combo: try KeyCombo(parsing: "ctrl+a"))).effect == .refused)
        _ = try await Self.act(fixture, .scroll(at: nil, dx: 0, dy: 3, unit: .line))
        #expect(await fixture.adb.shells("'input'").last == "'input' 'swipe' '540' '1200' '540' '840' '300'")
        #expect(try await Self.act(fixture, .click(at: .point(DisplayPoint(x: 1, y: 1), observation: "o_9"))).escalation == .observe)
    }

    @Test("Apps launch by package and URLs open through an intent, quoted for the device's shell")
    func launchAndOpen() async throws {
        let fixture = try await Self.fixture()
        #expect(try await Self.act(fixture, .launch(app: "com.example.app")).effect == .unverifiable)
        #expect(await fixture.adb.shells("monkey").last == "monkey -p com.example.app -c android.intent.category.LAUNCHER 1")
        #expect(try await Self.act(fixture, .launch(app: "com.example.app; reboot")).effect == .refused)
        let missing = try await Self.act(fixture, .launch(app: "com.missing.app"))
        #expect(missing.evidence == "com.missing.app isn't installed")
        _ = try await Self.act(fixture, .openURL("https://example.com/?q=$(reboot)"))
        #expect(await fixture.adb.shells("am start").last == "am start -a android.intent.action.VIEW -d 'https://example.com/?q=$(reboot)'")
        #expect(try await Self.act(fixture, .move(to: .point(DisplayPoint(x: 1, y: 1), observation: "o_1"))).effect == .refused)
    }
}
