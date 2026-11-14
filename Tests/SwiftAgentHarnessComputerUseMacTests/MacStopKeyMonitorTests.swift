#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

@Suite("macOS stop key")
struct MacStopKeyMonitorTests {
    @Test("Escape alone matches; Escape with modifiers does not")
    func plainEscape() throws {
        let stop = try KeyCombo(parsing: "escape")
        #expect(MacStopKeyMonitor.matches(keyCode: 53, flags: [], stopKey: stop))
        #expect(MacStopKeyMonitor.matches(keyCode: 53, flags: [.maskNonCoalesced], stopKey: stop))
        #expect(!MacStopKeyMonitor.matches(keyCode: 53, flags: [.maskCommand], stopKey: stop))
        #expect(!MacStopKeyMonitor.matches(keyCode: 12, flags: [], stopKey: stop))
    }

    @Test("A chord stop key needs exactly its modifiers")
    func chord() throws {
        let stop = try KeyCombo(parsing: "ctrl+option+cmd+escape")
        #expect(MacStopKeyMonitor.matches(keyCode: 53, flags: [.maskControl, .maskAlternate, .maskCommand], stopKey: stop))
        #expect(!MacStopKeyMonitor.matches(keyCode: 53, flags: [.maskControl, .maskCommand], stopKey: stop))
        #expect(!MacStopKeyMonitor.matches(keyCode: 53, flags: [.maskControl, .maskAlternate, .maskCommand, .maskShift], stopKey: stop))
    }

    @Test("Keys from the hardware or another process are the user's; keys this process posted are not")
    func userKeys() {
        #expect(MacStopKeyMonitor.isUserKey(sourcePID: 0, ownPID: 4_242))
        #expect(MacStopKeyMonitor.isUserKey(sourcePID: 77, ownPID: 4_242))
        #expect(!MacStopKeyMonitor.isUserKey(sourcePID: 4_242, ownPID: 4_242))
    }
}
#endif
