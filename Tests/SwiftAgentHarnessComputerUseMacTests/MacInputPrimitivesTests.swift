#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

@Suite("macOS input primitives")
struct MacInputPrimitivesTests {
    @Test("Cocoa's bottom-left rects convert once to CoreGraphics top-left points, and back")
    func coordinateConversion() {
        let primaryHeight: CGFloat = 982
        let cocoa = CGRect(x: 100, y: 700, width: 400, height: 200)
        let cg = MacCoordinateSpace.cgRect(fromCocoa: cocoa, primaryScreenHeight: primaryHeight)
        #expect(cg == CGRect(x: 100, y: 82, width: 400, height: 200))
        #expect(MacCoordinateSpace.cocoaRect(fromCG: cg, primaryScreenHeight: primaryHeight) == cocoa)
        let secondary = MacCoordinateSpace.cgRect(fromCocoa: CGRect(x: -1920, y: 982, width: 1920, height: 1080), primaryScreenHeight: primaryHeight)
        #expect(secondary.origin == CGPoint(x: -1920, y: -1080))
    }

    @Test("Display rects and CG rects map one to one")
    func displayRectBridge() {
        let rect = DisplayRect(x: 1, y: 2, width: 3, height: 4)
        #expect(DisplayRect(MacCoordinateSpace.cgRect(rect)) == rect)
        #expect(MacCoordinateSpace.cgPoint(DisplayPoint(x: 5, y: 6)) == CGPoint(x: 5, y: 6))
    }

    @Test("Key combos map to virtual key codes and modifier flags")
    func keyMapping() throws {
        let save = try #require(MacKeyMapping.event(for: try KeyCombo(parsing: "cmd+s")))
        #expect(save.keyCode == 1)
        #expect(save.flags.contains(.maskCommand))
        #expect(!save.flags.contains(.maskShift))
        let escape = try #require(MacKeyMapping.event(for: try KeyCombo(parsing: "esc")))
        #expect(escape.keyCode == 53)
        #expect(escape.flags.isEmpty)
        let arrow = try #require(MacKeyMapping.event(for: try KeyCombo(parsing: "shift+option+left")))
        #expect(arrow.keyCode == 123)
        #expect(arrow.flags.contains([.maskShift, .maskAlternate]))
        #expect(MacKeyMapping.event(for: try KeyCombo(parsing: "f12"))?.keyCode == 111)
        #expect(MacKeyMapping.event(for: try KeyCombo(parsing: "cmd+notakey")) == nil)
    }

    @Test("Modifier keys have key codes for explicit down and up events")
    func modifierKeyCodes() {
        #expect(MacKeyMapping.keyCode(for: .cmd) == 55)
        #expect(MacKeyMapping.keyCode(for: .shift) == 56)
        #expect(MacKeyMapping.keyCode(for: .option) == 58)
        #expect(MacKeyMapping.keyCode(for: .ctrl) == 59)
    }

    @Test("Typing chunks stay within 20 UTF-16 units and never split a grapheme")
    func textChunking() {
        let text = "Hello, wörld! 👋🏽 family: 👨‍👩‍👧‍👦 done."
        let chunks = MacTextChunker.chunks(text, maxUTF16: 20)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 || $0.count == 1 })
        for chunk in chunks {
            #expect(chunk.count == Array(chunk).count)
        }
        #expect(MacTextChunker.chunks("", maxUTF16: 20).isEmpty)
        let family = "👨‍👩‍👧‍👦"
        #expect(MacTextChunker.chunks(family, maxUTF16: 4) == [family])
    }
}
#endif
