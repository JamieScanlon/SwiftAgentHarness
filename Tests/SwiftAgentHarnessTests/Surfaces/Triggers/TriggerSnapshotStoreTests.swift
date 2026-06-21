import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerSnapshotStore")
struct TriggerSnapshotStoreTests {
    @Test("round-trip encode and decode by trigger id")
    func roundTrip() throws {
        let dir = try makeTempDir()
        let store = TriggerSnapshotStore(dataDirectory: dir)
        let trigger = HarnessTrigger(
            id: "webhook:delivery-abc",
            source: .webhook,
            sourceMetadata: ["routeName": "github"],
            payload: "hello",
            payloadFormat: .text,
            initiator: TriggerInitiator(kind: .external, id: "github"),
            trust: .knownParty
        )
        try store.save(trigger)
        let loaded = try store.load(triggerID: "webhook:delivery-abc")
        #expect(loaded == trigger)
    }

    @Test("not found throws with trigger id")
    func notFound() throws {
        let dir = try makeTempDir()
        let store = TriggerSnapshotStore(dataDirectory: dir)
        #expect(throws: TriggerSnapshotStoreError.notFound("missing-id")) {
            _ = try store.load(triggerID: "missing-id")
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
