import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventTrustResolver")
struct FileEventTrustResolverTests {
    @Test("sidecar trust is used when present")
    func sidecarTrust() throws {
        let dir = try makeTempDir()
        let event = dir.appendingPathComponent("evt.json")
        try Data("{}".utf8).write(to: event)
        let sidecar = FileEventTrustSidecar(trust: .knownParty, source: "webhook", routeName: "github")
        try JSONEncoder().encode(sidecar).write(to: FileEventQueueLayout.trustSidecarURL(for: event))
        let resolved = FileEventTrustResolver.resolve(for: event)
        #expect(resolved.trust == .knownParty)
        #expect(resolved.source == "webhook")
    }

    @Test("missing sidecar defaults to unknown-party")
    func missingSidecar() throws {
        let dir = try makeTempDir()
        let event = dir.appendingPathComponent("evt.json")
        try Data("{}".utf8).write(to: event)
        let resolved = FileEventTrustResolver.resolve(for: event)
        #expect(resolved.trust == .unknownParty)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-event-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
