#if os(macOS)
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Wakes and sleeps the display, keeps it awake, and tells whether the session is locked.
protocol MacDisplayPowering: Sendable {
    /// Declares user activity, which wakes a sleeping display, and keeps the display from idle sleep until the
    /// returned assertions are released.
    func holdAwake(reason: String) -> [IOPMAssertionID]
    func release(_ assertions: [IOPMAssertionID])
    var displayIsAsleep: Bool { get }
    /// The lock screen is up, so nothing but the user's password gets past it.
    var screenIsLocked: Bool { get }
    /// Locks the session now, as the Lock Screen command (⌃⌘Q) does.
    func lockScreen()
    /// Sleeps the display now, as `pmset displaysleepnow` does. With the Mac set to ask for its password
    /// immediately, this locks it.
    func sleepDisplay()
}

struct LiveMacDisplayPower: MacDisplayPowering {
    func holdAwake(reason: String) -> [IOPMAssertionID] {
        var assertions: [IOPMAssertionID] = []
        var activity = IOPMAssertionID(0)
        if IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &activity) == kIOReturnSuccess {
            assertions.append(activity)
        }
        var awake = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &awake
        ) == kIOReturnSuccess {
            assertions.append(awake)
        }
        return assertions
    }

    func release(_ assertions: [IOPMAssertionID]) {
        for assertion in assertions { IOPMAssertionRelease(assertion) }
    }

    var displayIsAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func lockScreen() {
        // Synthesizing the system's own lock shortcut is acceptable only because locking can never make the Mac
        // less safe. A private event source keeps the user's held modifiers out of it.
        let source = CGEventSource(stateID: .privateState)
        let q: CGKeyCode = 12
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: down) else { continue }
            event.flags = [.maskControl, .maskCommand]
            event.post(tap: .cghidEventTap)
        }
    }

    func sleepDisplay() {
        let wrangler = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard wrangler != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(wrangler) }
        IORegistryEntrySetCFProperty(wrangler, "IORequestIdle" as CFString, kCFBooleanTrue)
    }
}
#endif
