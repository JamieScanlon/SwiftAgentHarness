import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import SwiftData
import Testing

@Suite("Harness session persistence Gap 13 (per-agent API)")
struct SessionPersistenceGap13Tests {
    @Test func localNamedProfileReturnsEncodedObject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap13-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentId = SessionPersistenceLayout.defaultAgentId
        let local = try LocalHarnessSessionPersistence(root: root, agentId: agentId)
        let dir = try local.sessionAgentDirectory(agentId: agentId)
        let body: [String: Any] = [
            "default": ["provider": "openai", "tier": "1"],
            "backup": ["provider": "anthropic", "tier": "2"],
        ]
        let fileData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let url = dir.appendingPathComponent("auth-profiles.json", isDirectory: false)
        try fileData.write(to: url)

        guard let dData = try local.sessionAuthProfile(agentId: agentId, name: "default") else {
            Issue.record("expected default profile data")
            return
        }
        guard let bData = try local.sessionAuthProfile(agentId: agentId, name: "backup") else {
            Issue.record("expected backup profile data")
            return
        }
        let dObj = try JSONSerialization.jsonObject(with: dData) as? [String: Any]
        let bObj = try JSONSerialization.jsonObject(with: bData) as? [String: Any]
        #expect(dObj?["provider"] as? String == "openai")
        #expect(dObj?["tier"] as? String == "1")
        #expect(bObj?["provider"] as? String == "anthropic")
    }

    @Test func localMissingKeyOrFileReturnsNil() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap13-nil-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentId = SessionPersistenceLayout.defaultAgentId
        let local = try LocalHarnessSessionPersistence(root: root, agentId: agentId)
        #expect(try local.sessionAuthProfile(agentId: agentId, name: "nope") == nil)

        let dir = try local.sessionAgentDirectory(agentId: agentId)
        let body: [String: Any] = ["default": ["x": 1]]
        try JSONSerialization.data(withJSONObject: body).write(to: dir.appendingPathComponent("auth-profiles.json"))
        #expect(try local.sessionAuthProfile(agentId: agentId, name: "missing") == nil)
    }

    @Test func localEmptyNameReturnsNil() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap13-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentId = SessionPersistenceLayout.defaultAgentId
        let local = try LocalHarnessSessionPersistence(root: root, agentId: agentId)
        let dir = try local.sessionAgentDirectory(agentId: agentId)
        let body: [String: Any] = ["default": ["x": 1]]
        try JSONSerialization.data(withJSONObject: body).write(to: dir.appendingPathComponent("auth-profiles.json"))

        #expect(try local.sessionAuthProfile(agentId: agentId, name: "") == nil)
    }

    @Test func localNonObjectRootReturnsNilForNamedLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap13-arr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentId = SessionPersistenceLayout.defaultAgentId
        let local = try LocalHarnessSessionPersistence(root: root, agentId: agentId)
        let dir = try local.sessionAgentDirectory(agentId: agentId)
        try JSONSerialization.data(withJSONObject: [1, 2, 3]).write(to: dir.appendingPathComponent("auth-profiles.json"))
        #expect(try local.sessionAuthProfile(agentId: agentId, name: "x") == nil)
    }

    @Test func inMemoryMirrorsLocalAuthAndListAgents() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let aid = "alice"
        let dir = try mem.sessionAgentDirectory(agentId: aid)
        let body: [String: Any] = [
            "default": ["k": "v"],
            "alt": ["k": "w"],
        ]
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("auth-profiles.json"))

        let agents = try mem.listSessionAgentIdentifiers()
        #expect(agents.contains(aid))

        let sub = try mem.sessionAuthProfile(agentId: aid, name: "default")
        guard let sub else {
            Issue.record("expected default profile")
            return
        }
        let obj = try JSONSerialization.jsonObject(with: sub) as? [String: String]
        #expect(obj?["k"] == "v")
    }

    @Test func localListAgentsIsSortedAndFiltersHiddenAndFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap13-list-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let defaultAgentURL = SessionPersistenceLayout.agentRootDirectory(
            root: root,
            agentId: SessionPersistenceLayout.defaultAgentId
        )
        try? FileManager.default.removeItem(at: defaultAgentURL)
        _ = try local.sessionAgentDirectory(agentId: "zeta")
        _ = try local.sessionAgentDirectory(agentId: "alpha")
        let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
        try SessionPersistenceLayout.ensureDirectory(agentsRoot)
        try SessionPersistenceLayout.ensureDirectory(agentsRoot.appendingPathComponent(".hidden", isDirectory: true))
        try Data("not-an-agent-dir".utf8).write(to: agentsRoot.appendingPathComponent("README.txt", isDirectory: false))

        let ids = try local.listSessionAgentIdentifiers()
        #expect(ids == ["alpha", "zeta"])
    }

    @Test func inMemoryListAgentsIsSortedAndFiltersHiddenAndFiles() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let alpha = try mem.sessionAgentDirectory(agentId: "alpha")
        _ = try mem.sessionAgentDirectory(agentId: "zeta")
        let agentsRoot = alpha.deletingLastPathComponent()
        try SessionPersistenceLayout.ensureDirectory(agentsRoot.appendingPathComponent(".hidden", isDirectory: true))
        try Data("not-an-agent-dir".utf8).write(to: agentsRoot.appendingPathComponent("README.txt", isDirectory: false))

        let ids = try mem.listSessionAgentIdentifiers()
        #expect(ids == ["alpha", "zeta"])
    }

    @Test func listAgentsReturnsEmptyWhenAgentsRootMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap13-list-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try SessionPersistenceLayout.ensureDirectory(root)

        let local = try LocalHarnessSessionPersistence(root: root)
        let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
        try? FileManager.default.removeItem(at: agentsRoot)
        #expect(try local.listSessionAgentIdentifiers().isEmpty)

        let mem = InMemoryHarnessSessionPersistence()
        #expect(try mem.listSessionAgentIdentifiers().isEmpty)
    }

}
