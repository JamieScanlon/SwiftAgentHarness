#if os(macOS)
import AppKit
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

@Suite("macOS agent-active HUD state")
struct MacAgentActiveHUDStateTests {
    private func activity(
        _ status: ComputerUseSurfaceIntentPayload.Status,
        lifecycleID: String = "call-1",
        step: Int = 0,
        app: String? = nil,
        action: String? = nil
    ) -> ComputerUseSurfaceIntentPayload {
        ComputerUseSurfaceIntentPayload(
            target: "This Mac", lifecycleID: lifecycleID, status: status, step: step, maxSteps: 40, app: app, action: action
        )
    }

    @Test("A started session shows who is in control and how to stop it")
    func started() {
        var state = MacAgentActiveHUDState()
        #expect(!state.isVisible)
        state.apply(activity(.started))
        #expect(state.isVisible)
        #expect(state.title == "Agent is using This Mac")
        #expect(state.detail == "Step 0 of 40")
        #expect(state.stopHint.contains("Esc"))
    }

    @Test("Acting shows the step, app, and action; takeover says the user has control")
    func acting() {
        var state = MacAgentActiveHUDState()
        state.apply(activity(.acting, step: 3, app: "com.apple.TextEdit", action: "click"))
        #expect(state.detail == "Step 3 of 40 · com.apple.TextEdit · click")
        state.apply(activity(.takenOver, step: 3))
        #expect(state.title == "You have control of This Mac")
        #expect(state.isVisible)
    }

    @Test("The step shows against the current allotment and how many times it was extended")
    func extended() {
        var state = MacAgentActiveHUDState()
        for (extensions, phrase) in [(1, "extended once"), (2, "extended twice"), (3, "extended 3 times")] {
            state.apply(ComputerUseSurfaceIntentPayload(
                target: "This Mac", lifecycleID: "call-1", status: .acting, step: 34, maxSteps: 45, extensions: extensions
            ))
            #expect(state.detail == "Step 34 of 45, \(phrase)")
        }
    }

    @Test("Foreground input is announced until the next step")
    func foreground() {
        var state = MacAgentActiveHUDState()
        state.apply(activity(.acting, step: 1))
        state.noteForegroundDelivery(app: "com.apple.TextEdit")
        #expect(state.notice == "Brought com.apple.TextEdit to the front to type and click")
        state.apply(activity(.acting, step: 2))
        #expect(state.notice == nil)
    }

    @Test("Ending the session hides the HUD; a stale end from another run does not")
    func ended() {
        var state = MacAgentActiveHUDState()
        state.apply(activity(.acting, lifecycleID: "call-2", step: 1))
        state.apply(activity(.ended, lifecycleID: "call-1"))
        #expect(state.isVisible)
        state.apply(activity(.ended, lifecycleID: "call-2"))
        #expect(!state.isVisible)
        state.noteForegroundDelivery(app: "x")
        #expect(state.notice == nil, "nothing to announce with no session")
    }
}

/// Creates a real panel, which needs a window server. Opt in with `SWIFTAGENTHARNESS_MAC_SMOKE=1`.
@Suite(
    "macOS agent-active HUD panel",
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTAGENTHARNESS_MAC_SMOKE"] == "1")
)
@MainActor
struct MacAgentActiveHUDPanelTests {
    @Test("The panel never appears in screen captures and floats over every space without taking focus")
    func panel() {
        let panel = MacAgentActiveHUD.makePanel()
        #expect(panel.sharingType == .none)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.hidesOnDeactivate)
    }
}
#endif
