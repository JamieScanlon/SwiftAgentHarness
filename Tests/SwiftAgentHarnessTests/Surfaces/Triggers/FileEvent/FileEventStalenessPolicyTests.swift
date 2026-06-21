import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventStalenessPolicy")
struct FileEventStalenessPolicyTests {
    @Test("immediate stale at startup is deleted")
    func immediateStale() {
        let harnessStart = Date(timeIntervalSince1970: 2000)
        let mtime = Date(timeIntervalSince1970: 1000)
        let payload = FileEventPayload(type: .immediate, text: "x")
        let action = FileEventStalenessPolicy.startupAction(
            payload: payload,
            fileModificationDate: mtime,
            harnessStartTime: harnessStart,
            now: harnessStart
        )
        #expect(action == .delete)
    }

    @Test("one-shot past at fires late")
    func oneShotLate() {
        let harnessStart = Date(timeIntervalSince1970: 2000)
        let payload = FileEventPayload(type: .oneShot, text: "x", at: "1970-01-01T00:00:00Z")
        let action = FileEventStalenessPolicy.startupAction(
            payload: payload,
            fileModificationDate: harnessStart,
            harnessStartTime: harnessStart,
            now: harnessStart
        )
        #expect(action == .consume(missed: true))
    }

    @Test("periodic registers without catch-up")
    func periodicNoCatchUp() {
        let now = Date()
        let payload = FileEventPayload(type: .periodic, text: "x", schedule: "0 * * * *")
        let action = FileEventStalenessPolicy.startupAction(
            payload: payload,
            fileModificationDate: now,
            harnessStartTime: now,
            now: now
        )
        #expect(action == .registerPeriodic)
    }
}
