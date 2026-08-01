import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelRuntimeStateStore")
struct ChannelRuntimeStateStoreTests {
    private func makeStore() -> (store: ChannelRuntimeStateStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chan-state-\(UUID().uuidString)")
            .appendingPathComponent("channel_runtime_state.json")
        return (ChannelRuntimeStateStore(fileURL: url), url)
    }

    @Test("absent file reads as no overlay")
    func absentFile() throws {
        let (store, _) = makeStore()
        let overlay = try store.load()
        #expect(overlay.isEmpty)
    }

    @Test("empty file reads as no overlay rather than throwing")
    func emptyFile() throws {
        let (store, url) = makeStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        let overlay = try store.load()
        #expect(overlay.isEmpty)
    }

    @Test("a disable round-trips with its attribution")
    func disableRoundTrips() throws {
        let (store, _) = makeStore()
        let owner = UUID()
        try store.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: owner), reason: "cli")
        let overlay = try store.load()
        let entry = try #require(overlay["slack"])
        #expect(entry.disabled)
        #expect(entry.reason == "cli")
        #expect(entry.changedBy?.ownerAccountID == owner)
        #expect(entry.updatedAtMs > 0)
    }

    /// Re-enabling keeps the row. Deleting it would lose "explicitly re-enabled at T by X", which is
    /// the half of the audit trail that says a pause was deliberately lifted rather than never set.
    @Test("re-enable records disabled=false instead of removing the row")
    func reEnableKeepsRow() throws {
        let (store, _) = makeStore()
        try store.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: nil))
        try store.setDisabled(channel: .slack, disabled: false, changedBy: .owner(accountID: nil))
        let overlay = try store.load()
        let entry = try #require(overlay["slack"])
        #expect(entry.disabled == false)
    }

    @Test("channels are independent")
    func perChannelIsolation() throws {
        let (store, _) = makeStore()
        try store.setDisabled(channel: .slack, disabled: true, changedBy: nil)
        let overlay = try store.load()
        #expect(overlay["slack"]?.disabled == true)
        #expect(overlay["telegram"] == nil)
    }

    /// A ceiling that resets when its file is corrupted is a ceiling an attacker resets. The read
    /// path must refuse rather than answer "nothing is disabled".
    @Test("a corrupt file throws rather than reading as empty")
    func corruptFileThrows() throws {
        let (store, url) = makeStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: ChannelRuntimeStateError.self) { try store.load() }
    }

    /// The write path takes the opposite side of the same trade. If a corrupt file also blocked
    /// writes, anyone able to scribble one byte could wedge the owner out of ever disabling a
    /// channel again — the file would become a lock. Quarantine keeps the original bytes, makes the
    /// event visible, and lets the owner's explicit decision land.
    @Test("a corrupt file is quarantined on write, not truncated, and the decision lands")
    func corruptFileQuarantinedOnWrite() throws {
        let (store, url) = makeStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        try store.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: nil))

        let overlay = try store.load()
        #expect(overlay["slack"]?.disabled == true)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        #expect(siblings.contains { $0.hasPrefix("channel_runtime_state.json.corrupt-") })
    }
}
