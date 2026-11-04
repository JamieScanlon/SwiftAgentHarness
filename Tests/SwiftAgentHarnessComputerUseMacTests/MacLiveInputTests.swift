#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

@Suite("macOS live view input")
struct MacLiveInputTests {
    /// A 1440×900 pt display shown in a 720×450 frame.
    private let space = MacLiveFrameSpace(display: CGRect(x: 0, y: 0, width: 1440, height: 900), frame: ImagePixelSize(width: 720, height: 450))

    private func events(_ input: DisplayLiveViewInput, held: MouseButton? = nil) -> [MacInputEvent] {
        MacLiveInput.events(for: input, space: space, held: held)
    }

    @Test("Frame points map to the display, clamped to the frame; moves with a button down are drags")
    func pointer() {
        #expect(events(.mouse(.down, x: 360, y: 225, button: .left, clickCount: 2, modifiers: [.shift])) == [
            .mouseMove(CGPoint(x: 720, y: 450)), .mouseDown(CGPoint(x: 720, y: 450), .left, 2, .maskShift),
        ])
        #expect(events(.mouse(.move, x: 9_999, y: -5, button: nil, clickCount: 1, modifiers: [])) == [.mouseMove(CGPoint(x: 1438, y: 0))])
        #expect(events(.mouse(.move, x: 10, y: 10, button: nil, clickCount: 1, modifiers: []), held: .left) == [.mouseDrag(CGPoint(x: 20, y: 20), .left, [])])
        #expect(events(.mouse(.up, x: 10, y: 10, button: .left, clickCount: 1, modifiers: [])) == [.mouseUp(CGPoint(x: 20, y: 20), .left, 1, [])])
        #expect(events(.wheel(x: 0, y: 0, dx: 0, dy: 120, modifiers: [])) == [.scroll(at: .zero, wheelY: -120, wheelX: 0, unit: .pixel)])
    }

    @Test("Characters are typed on the way down; named keys and modifiers go by key code")
    func keys() {
        #expect(events(.key(down: true, key: "a", code: "KeyA", keyCode: 65, text: "a", modifiers: [])) == [.unicode("a")])
        #expect(events(.key(down: false, key: "a", code: "KeyA", keyCode: 65, text: "a", modifiers: [])).isEmpty)
        #expect(events(.key(down: true, key: "Enter", code: "Enter", keyCode: 13, text: "\r", modifiers: [])) == [.keyDown(CGKeyCode(kVK_Return), [])])
        #expect(events(.key(down: true, key: "Delete", code: "Delete", keyCode: 46, text: nil, modifiers: [])) == [.keyDown(CGKeyCode(kVK_ForwardDelete), [])])
        #expect(events(.key(down: true, key: "Shift", code: "ShiftLeft", keyCode: 16, text: nil, modifiers: [.shift])) == [.keyDown(CGKeyCode(kVK_Shift), .maskShift)])
        #expect(events(.key(down: true, key: "c", code: "KeyC", keyCode: 67, text: "c", modifiers: [.cmd])) == [.keyDown(CGKeyCode(kVK_ANSI_C), .maskCommand)])
        #expect(events(.text("hello")) == [.unicode("hello")])
    }

    @Test("Only a target that serves live frames declares a stream, and it takes input only during takeover")
    func target() async throws {
        let poster = RecordingEventPoster()
        var configuration = MacHostDisplayTarget.Configuration(
            excludedBundleIDs: [], permissionProbe: FakePermissionProbe(granted: [.screenCapture, .accessibility, .postEvents]), eventPoster: poster
        )
        #expect(MacHostDisplayTarget(configuration: configuration).manifest.observerAccess == .none)
        configuration.servesLiveFrames = true
        let target = MacHostDisplayTarget(configuration: configuration)
        #expect(target.manifest.observerAccess == .stream)
        let lease = try await target.lease(LeaseRequest(
            target: MacHostDisplayTarget.defaultID, agentID: "agent", grants: [],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)), initiator: .operator, userPresent: true
        ))
        await target.noteLiveFrame(space)
        let click = DisplayLiveViewInput.mouse(.down, x: 10, y: 10, button: .left, clickCount: 1, modifiers: [])
        try await target.liveInput(lease, click)
        #expect(poster.count == 0)
        try await target.takeover(lease, on: true)
        try await target.liveInput(lease, click)
        #expect(poster.count == 2)
        #expect(poster.deliveries.allSatisfy { $0 == .foreground })
        await target.release(lease, reason: .completed)
    }

    @Test("A target that doesn't serve live frames gives none out")
    func noFrames() async throws {
        let target = MacHostDisplayTarget(configuration: MacHostDisplayTarget.Configuration(
            excludedBundleIDs: [], permissionProbe: FakePermissionProbe(granted: []), eventPoster: RecordingEventPoster()
        ))
        let lease = try await target.lease(LeaseRequest(
            target: MacHostDisplayTarget.defaultID, agentID: "agent", grants: [],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)), initiator: .operator, userPresent: true
        ))
        #expect(try await target.liveFrame(lease) == nil)
        await target.release(lease, reason: .completed)
    }
}
#endif
