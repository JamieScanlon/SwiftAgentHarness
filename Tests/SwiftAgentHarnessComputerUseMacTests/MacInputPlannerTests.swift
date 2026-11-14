#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

@Suite("macOS input planning")
struct MacInputPlannerTests {
    private let point = CGPoint(x: 100, y: 200)

    @Test("A double click moves, settles, then sends two down/up pairs with click states 1 and 2")
    func doubleClick() {
        let events = MacInputPlanner.click(at: point, button: .left, count: 2, modifiers: [])
        #expect(events.first == .mouseMove(point))
        #expect(events.contains(.pause(milliseconds: MacInputPlanner.settleMilliseconds)))
        let downs = events.compactMap { if case .mouseDown(_, _, let state, _) = $0 { return state } else { return nil } }
        let ups = events.compactMap { if case .mouseUp(_, _, let state, _) = $0 { return state } else { return nil } }
        #expect(downs == [1, 2])
        #expect(ups == [1, 2])
    }

    @Test("Click modifiers ride on the mouse events as flags")
    func clickModifiers() {
        let events = MacInputPlanner.click(at: point, button: .right, count: 1, modifiers: [.cmd, .shift])
        guard case .mouseDown(_, let button, _, let flags)? = events.first(where: { if case .mouseDown = $0 { return true } else { return false } }) else {
            Issue.record("no mouse down")
            return
        }
        #expect(button == .right)
        #expect(flags.contains([.maskCommand, .maskShift]))
    }

    @Test("A chord presses modifiers first and releases them last, in reverse")
    func chordOrdering() throws {
        let events = try #require(MacInputPlanner.key(try KeyCombo(parsing: "cmd+shift+s"), repeatCount: 1))
        let codes = events.compactMap { event -> String? in
            switch event {
            case .keyDown(let code, _): return "d\(code)"
            case .keyUp(let code, _): return "u\(code)"
            default: return nil
            }
        }
        #expect(codes == ["d56", "d55", "d1", "u1", "u55", "u56"])
    }

    @Test("Repeated keys repeat only the key, inside one modifier hold")
    func repeatedKey() throws {
        let events = try #require(MacInputPlanner.key(try KeyCombo(parsing: "down"), repeatCount: 3))
        #expect(events.filter { if case .keyDown(125, _) = $0 { return true } else { return false } }.count == 3)
    }

    @Test("Unknown keys produce no plan")
    func unknownKey() throws {
        #expect(MacInputPlanner.key(try KeyCombo(parsing: "cmd+hyper"), repeatCount: 1) == nil)
    }

    @Test("Typing becomes Unicode chunks")
    func typing() {
        let events = MacInputPlanner.type(String(repeating: "a", count: 45))
        #expect(events == [.unicode(String(repeating: "a", count: 20)), .unicode(String(repeating: "a", count: 20)), .unicode("aaaaa")])
    }

    @Test("A positive dy scrolls down, sent as a negative wheel delta")
    func scrollSign() {
        #expect(MacInputPlanner.scroll(at: point, dx: 2, dy: 3, unit: .line).last == .scroll(at: point, wheelY: -3, wheelX: -2, unit: .line))
    }

    @Test("A drag presses at the first point, drags through the rest, and always releases at the last")
    func drag() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)]
        let events = MacInputPlanner.drag(path, modifiers: [])
        #expect(events.contains { if case .mouseDown(CGPoint(x: 0, y: 0), .left, 1, _) = $0 { return true } else { return false } })
        #expect(events.filter { if case .mouseDrag = $0 { return true } else { return false } }.count == 2)
        #expect(events.last == .mouseUp(CGPoint(x: 20, y: 20), .left, 1, []))
    }

    @Test("Delivery prefers the semantic action, then the process, then the foreground only when allowed")
    func deliveryLadder() {
        #expect(MacDeliveryPlanner.rungs(semanticAvailable: true, foregroundAllowed: false) == [.semantic, .process])
        #expect(MacDeliveryPlanner.rungs(semanticAvailable: false, foregroundAllowed: false) == [.process])
        #expect(MacDeliveryPlanner.rungs(semanticAvailable: false, foregroundAllowed: true) == [.process, .foreground])
    }

    @Test("Held keys and buttons are tracked so cleanup can release every one")
    func heldTracking() {
        var held = MacHeldInput()
        held.apply(.keyDown(56, []))
        held.apply(.mouseDown(.zero, .left, 1, []))
        held.apply(.keyDown(1, []))
        held.apply(.keyUp(1, []))
        #expect(held.releaseEvents(at: .zero) == [.mouseUp(.zero, .left, 1, []), .keyUp(56, [])])
        held.apply(.mouseUp(.zero, .left, 1, []))
        held.apply(.keyUp(56, []))
        #expect(held.releaseEvents(at: .zero).isEmpty)
    }
}
#endif
