#if os(macOS)
import CoreGraphics
import Foundation
import Synchronization
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

/// A desktop the test lays out: running apps, the frontmost one, and on-screen windows front to back.
final class FakeMacWorkspace: MacWorkspaceReading {
    struct State {
        var apps: [MacRunningApp] = []
        var frontmost: pid_t?
        var windows: [MacWindowEntry] = []
        var browsers = MacBrowsers(installed: [], defaultBundleID: nil)
    }

    private let state: Mutex<State>

    init(_ state: State) {
        self.state = Mutex(state)
    }

    func frontmostApp() async -> MacRunningApp? {
        state.withLock { state in state.apps.first { $0.pid == state.frontmost } }
    }

    func runningApp(pid: pid_t) async -> MacRunningApp? {
        state.withLock { $0.apps.first { $0.pid == pid } }
    }

    func windows() async -> [MacWindowEntry] {
        state.withLock(\.windows)
    }

    func browsers() async -> MacBrowsers {
        state.withLock(\.browsers)
    }
}

enum MacDesktopFixtures {
    static let launched = Date(timeIntervalSince1970: 1_000)
    static let harness = MacRunningApp(pid: 90_001, identity: AppIdentity(bundleID: "com.example.harness"), launchDate: launched)
    static let textEdit = MacRunningApp(pid: 90_002, identity: AppIdentity(bundleID: "com.apple.TextEdit"), launchDate: launched)
    static let notes = MacRunningApp(pid: 90_003, identity: AppIdentity(bundleID: "com.apple.Notes"), launchDate: launched)
    static let dock = MacRunningApp(pid: 90_004, identity: AppIdentity(bundleID: "com.apple.dock"), launchDate: launched)

    static let harnessWindow = MacWindowEntry(pid: harness.pid, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    static let notesWindow = MacWindowEntry(pid: notes.pid, layer: 0, bounds: CGRect(x: 100, y: 100, width: 400, height: 400))
    static let textEditWindow = MacWindowEntry(pid: textEdit.pid, layer: 0, bounds: CGRect(x: 200, y: 200, width: 600, height: 500))
    static let dockWindow = MacWindowEntry(pid: dock.pid, layer: 20, bounds: CGRect(x: 0, y: 650, width: 1000, height: 50))

    /// The harness in front, as it is while the user waits on an agent; Notes then TextEdit behind it.
    static func harnessInFront() -> FakeMacWorkspace.State {
        FakeMacWorkspace.State(
            apps: [harness, textEdit, notes, dock],
            frontmost: harness.pid,
            windows: [dockWindow, harnessWindow, notesWindow, textEditWindow]
        )
    }
}

@Suite("macOS workspace: which app input lands on")
struct MacAppFocusTests {
    private typealias F = MacDesktopFixtures

    @Test("A point lands on the app whose window is under it, past other apps' normal windows")
    func pastOtherNormalWindows() {
        let windows = [F.dockWindow, F.harnessWindow, F.notesWindow, F.textEditWindow]
        #expect(MacAppFocus.point(CGPoint(x: 300, y: 300), landsOn: F.textEdit.pid, windows: windows, ignoring: -1))
    }

    @Test("A point under a floating window of another app, such as the Dock, does not land on the app")
    func floatingWindowBlocks() {
        let windows = [F.dockWindow, F.textEditWindow]
        #expect(!MacAppFocus.point(CGPoint(x: 300, y: 680), landsOn: F.textEdit.pid, windows: windows, ignoring: -1))
    }

    @Test("A point outside every window of the app does not land on it")
    func outsideTheApp() {
        #expect(!MacAppFocus.point(CGPoint(x: 900, y: 50), landsOn: F.textEdit.pid, windows: [F.textEditWindow], ignoring: -1))
    }

    @Test("The harness's own floating windows are ignored, since they let clicks through")
    func ownWindowsIgnored() {
        let hud = MacWindowEntry(pid: 4_242, layer: 25, bounds: CGRect(x: 250, y: 250, width: 100, height: 40))
        #expect(MacAppFocus.point(CGPoint(x: 300, y: 260), landsOn: F.textEdit.pid, windows: [hud, F.textEditWindow], ignoring: 4_242))
    }

    @Test("Pages open in the default browser when it is granted, else in another granted browser, else nowhere")
    func browserChoice() {
        let browsers = MacBrowsers(installed: ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox"], defaultBundleID: "com.google.Chrome")
        #expect(MacAppFocus.browser(granted: ["com.google.Chrome", "com.apple.Safari"], browsers) == "com.google.Chrome")
        #expect(MacAppFocus.browser(granted: ["com.apple.Safari", "org.mozilla.firefox"], browsers) == "com.apple.Safari")
        #expect(MacAppFocus.browser(granted: ["com.apple.TextEdit"], browsers) == nil)
    }
}

@Suite("macOS host display target: working beside the harness's own app")
struct MacHostDisplayTargetFocusTests {
    private typealias F = MacDesktopFixtures

    private func target(_ desktop: FakeMacWorkspace.State, poster: RecordingEventPoster = RecordingEventPoster()) -> MacHostDisplayTarget {
        MacHostDisplayTarget(configuration: MacHostDisplayTarget.Configuration(
            excludedBundleIDs: [F.harness.identity.bundleID],
            permissionProbe: FakePermissionProbe(granted: [.screenCapture, .accessibility, .postEvents]),
            eventPoster: poster,
            workspace: FakeMacWorkspace(desktop)
        ))
    }

    private func request(_ grants: [ComputerUseGrant]) -> LeaseRequest {
        LeaseRequest(
            target: MacHostDisplayTarget.defaultID,
            agentID: "agent",
            grants: grants,
            budgets: ComputerUseBudgets(maxSteps: 10, maxDuration: .seconds(60)),
            operatorInitiated: true,
            userPresent: true
        )
    }

    private static let textEditGrant: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .full)]
    private static let treeOnly = ObserveRequest(modes: [.accessibility], scope: .display(nil))

    @Test("With the harness in front, the layout's focused app is the granted app with the frontmost window")
    func describeSkipsHarness() async throws {
        let target = target(F.harnessInFront())
        let lease = try await target.lease(request(Self.textEditGrant))
        #expect(try await target.describe(lease).focusedApp == F.textEdit.identity)
    }

    @Test("A granted frontmost app is the focused app")
    func grantedFrontmostWins() async throws {
        var desktop = F.harnessInFront()
        desktop.frontmost = F.notes.pid
        let target = target(desktop)
        let lease = try await target.lease(request(Self.textEditGrant + [.app(bundleID: "com.apple.Notes", tier: .full)]))
        #expect(try await target.describe(lease).focusedApp == F.notes.identity)
    }

    @Test("With no granted app on screen there is no focused app")
    func nothingGranted() async throws {
        let target = target(F.harnessInFront())
        let lease = try await target.lease(request([.app(bundleID: "com.apple.Mail", tier: .full)]))
        #expect(try await target.describe(lease).focusedApp == nil)
    }

    @Test("A display observation is pinned to the granted app behind the harness")
    func observationPinned() async throws {
        let target = target(F.harnessInFront())
        let lease = try await target.lease(request(Self.textEditGrant))
        let observation = try await target.observe(lease, Self.treeOnly)
        #expect(observation.target.app == F.textEdit.identity)
        #expect(observation.target.pid == F.textEdit.pid)
    }

    @Test("Keys go to the granted app behind the harness, never to the harness")
    func keysToWorkingApp() async throws {
        let poster = RecordingEventPoster()
        let target = target(F.harnessInFront(), poster: poster)
        let lease = try await target.lease(request(Self.textEditGrant))
        let outcomes = try await target.act(lease, ActionBatch([.key(combo: try KeyCombo(parsing: "cmd+n"))]))
        #expect(outcomes.first?.effect == .unverifiable)
        #expect(poster.count > 0)
        #expect(poster.deliveries.allSatisfy { $0 == .process(F.textEdit.pid) })
    }

    @Test("Keys are refused, and nothing is posted, when no granted app is on screen")
    func keysWithoutWorkingApp() async throws {
        let poster = RecordingEventPoster()
        let target = target(F.harnessInFront(), poster: poster)
        let lease = try await target.lease(request([.app(bundleID: "com.apple.Mail", tier: .full)]))
        let outcomes = try await target.act(lease, ActionBatch([
            .key(combo: try KeyCombo(parsing: "cmd+n")),
            .type(text: "hello"),
        ]))
        #expect(outcomes.first?.effect == .refused)
        #expect(poster.count == 0)
    }

    @Test("A coordinate click over the pinned app's window goes to that app")
    func clickOverWindow() async throws {
        let poster = RecordingEventPoster()
        let target = target(F.harnessInFront(), poster: poster)
        let lease = try await target.lease(request(Self.textEditGrant))
        let observation = try await target.observe(lease, Self.treeOnly)
        let outcomes = try await target.act(lease, ActionBatch([.click(at: .point(DisplayPoint(x: 300, y: 300), observation: observation.id))]))
        #expect(outcomes.first?.effect == .unverifiable)
        #expect(poster.count > 0)
        #expect(poster.deliveries.allSatisfy { $0 == .process(F.textEdit.pid) })
    }

    @Test("A coordinate click over the Dock or empty desktop is refused with an observe escalation")
    func clickOffWindow() async throws {
        let poster = RecordingEventPoster()
        let target = target(F.harnessInFront(), poster: poster)
        let lease = try await target.lease(request(Self.textEditGrant))
        let observation = try await target.observe(lease, Self.treeOnly)
        for point in [DisplayPoint(x: 300, y: 680), DisplayPoint(x: 950, y: 100)] {
            let outcome = try await target.act(lease, ActionBatch([.click(at: .point(point, observation: observation.id))])).first
            #expect(outcome?.effect == .refused)
            #expect(outcome?.escalation == .observe)
        }
        #expect(poster.count == 0)
    }

    @Test("A menu with no app named is refused when no granted app is on screen")
    func menuWithoutWorkingApp() async throws {
        let target = target(F.harnessInFront())
        let lease = try await target.lease(request([.app(bundleID: "com.apple.Mail", tier: .full)]))
        let outcome = try await target.act(lease, ActionBatch([.menu(path: ["File", "New"])])).first
        #expect(outcome?.effect == .refused)
        #expect(outcome?.evidence?.contains("no granted app") == true, "\(outcome?.evidence ?? "")")
    }

    @Test("Opening a page is refused when no browser is granted")
    func openURLNeedsBrowser() async throws {
        var desktop = F.harnessInFront()
        desktop.browsers = MacBrowsers(installed: ["com.apple.Safari"], defaultBundleID: "com.apple.Safari")
        let target = target(desktop)
        let lease = try await target.lease(request(Self.textEditGrant + [.domain("example.com", tier: .click)]))
        let outcome = try await target.act(lease, ActionBatch([.openURL("https://example.com")])).first
        #expect(outcome?.effect == .refused)
        #expect(outcome?.evidence?.contains("browser") == true, "\(outcome?.evidence ?? "")")
    }
}
#endif
