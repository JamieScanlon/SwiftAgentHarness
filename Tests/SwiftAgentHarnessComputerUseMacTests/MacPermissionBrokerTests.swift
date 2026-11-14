#if os(macOS)
import Foundation
import Synchronization
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

final class FakePermissionProbe: MacPermissionProbing {
    private let granted: Mutex<Set<DisplayPlatformPermission>>
    private let requests = Mutex<[DisplayPlatformPermission]>([])

    init(granted: Set<DisplayPlatformPermission>) {
        self.granted = Mutex(granted)
    }

    func isGranted(_ permission: DisplayPlatformPermission) -> Bool {
        granted.withLock { $0.contains(permission) }
    }

    func request(_ permission: DisplayPlatformPermission) -> Bool {
        requests.withLock { $0.append(permission) }
        return isGranted(permission)
    }

    func revoke(_ permission: DisplayPlatformPermission) {
        _ = granted.withLock { $0.remove(permission) }
    }

    var requested: [DisplayPlatformPermission] { requests.withLock { $0 } }
}

@Suite("macOS permission broker")
struct MacPermissionBrokerTests {
    @Test("A snapshot preflights each required permission separately")
    func snapshot() {
        let broker = MacPermissionBroker(probe: FakePermissionProbe(granted: [.screenCapture, .postEvents]))
        let snapshot = broker.snapshot([.screenCapture, .accessibility, .postEvents])
        #expect(snapshot.states == [.screenCapture: .granted, .accessibility: .denied, .postEvents: .granted])
        #expect(snapshot.missing([.screenCapture, .accessibility, .postEvents]) == [.accessibility])
    }

    @Test("Revocation shows up on the next snapshot; nothing is cached")
    func revocationIsLive() {
        let probe = FakePermissionProbe(granted: [.screenCapture, .accessibility])
        let broker = MacPermissionBroker(probe: probe)
        #expect(broker.snapshot([.accessibility]).missing([.accessibility]).isEmpty)
        probe.revoke(.accessibility)
        #expect(broker.snapshot([.accessibility]).missing([.accessibility]) == [.accessibility])
    }

    @Test("Requests go only to permissions that are missing")
    func requestsOnlyMissing() {
        let probe = FakePermissionProbe(granted: [.screenCapture])
        let broker = MacPermissionBroker(probe: probe)
        _ = broker.requestMissing([.screenCapture, .accessibility, .postEvents])
        #expect(probe.requested == [.accessibility, .postEvents])
    }

    @Test("The onboarding checklist explains each permission, deep-links to its pane, and flags a relaunch for capture")
    func checklist() throws {
        let broker = MacPermissionBroker(probe: FakePermissionProbe(granted: [.accessibility]))
        let items = broker.checklist([.screenCapture, .accessibility, .postEvents, .inputMonitoring])
        #expect(items.map(\.permission) == [.screenCapture, .accessibility, .postEvents, .inputMonitoring])
        #expect(items.map(\.granted) == [false, true, false, false])
        #expect(items.allSatisfy { !$0.explanation.isEmpty })
        #expect(items.allSatisfy { $0.settingsURL?.scheme == "x-apple.systempreferences" })
        let capture = try #require(items.first)
        #expect(capture.relaunchAfterGrant)
        #expect(!items[1].relaunchAfterGrant)
    }
}
#endif
