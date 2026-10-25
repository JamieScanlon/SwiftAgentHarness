#if os(macOS)
import CoreGraphics
import Foundation
import Synchronization
import SwiftAgentHarness

/// Watches for the user's stop key from any app and calls `onStop`.
///
/// A listen-only event tap: it needs only Input Monitoring and cannot swallow or alter events, which is the
/// lower-risk option (a modifying tap installed while Accessibility is revoked has been reported to hang input).
/// The primary guarantee is elsewhere: the harness never synthesizes the stop key while a session is active.
public final class MacStopKeyMonitor: Sendable {
    private let stopKey: KeyCombo
    private let onStop: @Sendable () -> Void
    private let stopRequested = Atomic<Bool>(false)
    private let started = Atomic<Bool>(false)

    public init(stopKey: KeyCombo = KeyCombo(modifiers: [], key: "escape"), onStop: @escaping @Sendable () -> Void) {
        self.stopKey = stopKey
        self.onStop = onStop
    }

    /// Installs the tap on its own run-loop thread. Returns `false` when it cannot be created, usually because
    /// Input Monitoring is not granted.
    @discardableResult
    public func start() -> Bool {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return true }
        stopRequested.store(false, ordering: .releasing)
        let created = Atomic<Bool>(false)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            // The tap and its run loop live only on this thread.
            let holder = TapHolder(monitor: self)
            let pointer = Unmanaged.passUnretained(holder).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: Self.callback,
                userInfo: pointer
            ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                ready.signal()
                return
            }
            holder.tap = tap
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            created.store(true, ordering: .releasing)
            ready.signal()
            while !stopRequested.load(ordering: .acquiring) {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            withExtendedLifetime(holder) {}
        }
        thread.name = "SwiftAgentHarness.computer-use.stop-key"
        thread.start()
        ready.wait()
        let ok = created.load(ordering: .acquiring)
        if !ok { started.store(false, ordering: .releasing) }
        return ok
    }

    public func stop() {
        guard started.exchange(false, ordering: .acquiringAndReleasing) else { return }
        stopRequested.store(true, ordering: .releasing)
    }

    deinit {
        stopRequested.store(true, ordering: .releasing)
    }

    static func matches(keyCode: Int64, flags: CGEventFlags, stopKey: KeyCombo) -> Bool {
        guard let mapped = MacKeyMapping.event(for: stopKey), Int64(mapped.keyCode) == keyCode else { return false }
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        return flags.intersection(relevant) == mapped.flags.intersection(relevant)
    }

    /// Owned by the tap thread; the callback runs on that thread's run loop.
    private final class TapHolder {
        let monitor: MacStopKeyMonitor
        var tap: CFMachPort?

        init(monitor: MacStopKeyMonitor) {
            self.monitor = monitor
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let holder = Unmanaged<TapHolder>.fromOpaque(userInfo).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables slow taps; listen-only taps are cheap, so turn it back on.
            if let tap = holder.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            let monitor = holder.monitor
            if matches(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags, stopKey: monitor.stopKey) {
                monitor.onStop()
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
#endif
