import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventIngressAdapter")
struct FileEventIngressAdapterTests {
    @Test("maps payload to HarnessTrigger")
    func mapping() throws {
        let dir = try makeTempDir()
        let event = dir.appendingPathComponent("evt.json")
        try JSONEncoder().encode(FileEventPayload(type: .immediate, text: "hello", channelId: "ch1")).write(to: event)
        let adapter = FileEventIngressAdapter()
        let trigger = adapter.makeTrigger(
            payload: FileEventPayload(type: .immediate, text: "hello", channelId: "ch1"),
            trust: FileEventTrustSidecar(trust: .knownParty, source: "webhook"),
            eventURL: event,
            eventsDirectory: dir
        )
        #expect(trigger.source == .fileEvent)
        #expect(trigger.trust == .knownParty)
        #expect(trigger.payload.contains("hello"))
        #expect(trigger.sourceMetadata["channelId"] == "ch1")
        #expect(trigger.id.hasPrefix("file-event:evt.json:"))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-event-ingress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
