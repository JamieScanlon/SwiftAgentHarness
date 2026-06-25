import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Permission rule store scoping")
struct PermissionRuleStoreTests {
    @Test("scopes encode/decode by kind and value")
    func scopeRoundTrips() throws {
        let scopes: [PermissionRuleScope] = [
            .toolName("write_file"),
            .commandName("git"),
            .exactCommand("git push origin main"),
            .directory("/repo"),
        ]
        let data = try JSONEncoder().encode(scopes)
        let decoded = try JSONDecoder().decode([PermissionRuleScope].self, from: data)
        #expect(decoded == scopes)
    }

    @Test("exact-command scope is distinct from command-name scope")
    func exactVsCommandName() async {
        let store = InMemoryPermissionRuleStore()
        await store.add(.exactCommand("git push origin main"))
        #expect(await store.isGranted(.exactCommand("git push origin main")))
        #expect(await store.isGranted(.commandName("git")) == false)
        #expect(await store.isGranted(.exactCommand("git status")) == false)
    }

    @Test("grantedToolNames extracts only tool-name scopes")
    func grantedToolNames() async {
        let store = InMemoryPermissionRuleStore()
        await store.add(.toolName("write_file"))
        await store.add(.toolName("edit_file"))
        await store.add(.commandName("git"))
        #expect(await store.grantedToolNames() == ["edit_file", "write_file"])
    }

    @Test("file-backed store persists rules across instances")
    func diskPersistence() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-rules-\(UUID().uuidString)")
            .appendingPathComponent("rules.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = FilePermissionRuleStore(fileURL: url)
        await first.add(.toolName("write_file"))
        await first.add(.commandName("git"))

        // A fresh instance reading the same file sees the persisted rules.
        let second = FilePermissionRuleStore(fileURL: url)
        #expect(await second.isGranted(.toolName("write_file")))
        #expect(await second.isGranted(.commandName("git")))
        #expect(await second.list().count == 2)

        await second.remove(.commandName("git"))
        let third = FilePermissionRuleStore(fileURL: url)
        #expect(await third.isGranted(.commandName("git")) == false)
        #expect(await third.isGranted(.toolName("write_file")))
    }

    @Test("exec grant adapter maps command names onto command-name scopes")
    func execGrantAdapter() async {
        let rules = InMemoryPermissionRuleStore()
        let adapter = PermissionRuleExecApprovalGrantStore(store: rules)
        await adapter.add(commandName: "git")
        #expect(await adapter.isGranted(commandName: "git"))
        #expect(await rules.isGranted(.commandName("git")))
        #expect(await adapter.list() == ["git"])
        await adapter.remove(commandName: "git")
        #expect(await adapter.isGranted(commandName: "git") == false)
    }

    @Test("exec store durable grants persist through a disk-backed rule store")
    func execStoreWithDiskBackedRules() async {
        let rules = InMemoryPermissionRuleStore()
        let grantStore = PermissionRuleExecApprovalGrantStore(store: rules)
        let store = ExecApprovalStore(grantStore: grantStore)
        await store.registerPending(id: "p1", command: "git push origin main")
        _ = await store.resolve(id: "p1", approved: true, durable: true)
        #expect(await rules.isGranted(.commandName("git")))
        #expect(await store.isDurableApproved(command: "git status"))
    }
}
