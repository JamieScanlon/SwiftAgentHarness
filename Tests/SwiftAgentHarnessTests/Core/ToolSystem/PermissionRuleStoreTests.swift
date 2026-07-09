import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Permission rule store scoping")
struct PermissionRuleStoreTests {
    @Test("scopes encode/decode by kind and value")
    func scopeRoundTrips() throws {
        let owner = UUID()
        let scopes: [PermissionRuleScope] = [
            .toolName("write_file"),
            .ownerToolName(ownerAccountID: owner, toolName: "edit_file"),
            .toolRule(.argumentMatcher(toolName: "bash", pattern: "npm run *"), ownerAccountID: owner),
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

    @Test("grantedToolNames extracts legacy tool-name scopes when owner is nil")
    func grantedToolNamesLegacy() async {
        let store = InMemoryPermissionRuleStore()
        await store.add(.toolName("write_file"))
        await store.add(.toolName("edit_file"))
        await store.add(.commandName("git"))
        #expect(await store.grantedToolNames(ownerAccountID: nil, strictTenancy: false) == ["edit_file", "write_file"])
    }

    @Test("grantedToolNames returns only matching owner-scoped grants")
    func grantedToolNamesOwnerScoped() async {
        let ownerA = UUID()
        let ownerB = UUID()
        let store = InMemoryPermissionRuleStore()
        await store.add(.ownerToolName(ownerAccountID: ownerA, toolName: "write_file"))
        await store.add(.ownerToolName(ownerAccountID: ownerB, toolName: "edit_file"))
        await store.add(.toolName("legacy_tool"))

        #expect(await store.grantedToolNames(ownerAccountID: ownerA, strictTenancy: true) == ["write_file"])
        #expect(await store.grantedToolNames(ownerAccountID: ownerB, strictTenancy: true) == ["edit_file"])
        #expect(await store.grantedToolNames(ownerAccountID: ownerA, strictTenancy: false) == ["write_file"])
        #expect(await store.grantedToolNames(ownerAccountID: ownerB, strictTenancy: false) == ["edit_file"])
    }

    @Test("strict tenancy ignores legacy global tool-name grants")
    func strictTenancyIgnoresLegacyToolName() async {
        let owner = UUID()
        let store = InMemoryPermissionRuleStore()
        await store.add(.toolName("legacy_tool"))
        await store.add(.ownerToolName(ownerAccountID: owner, toolName: "scoped_tool"))

        #expect(await store.grantedToolNames(ownerAccountID: owner, strictTenancy: true) == ["scoped_tool"])
        #expect(await store.grantedToolNames(ownerAccountID: nil, strictTenancy: true).isEmpty)
    }

    @Test("addToolGrant and removeToolGrant use owner scope when owner is known")
    func addRemoveToolGrantOwnerScoped() async {
        let owner = UUID()
        let store = InMemoryPermissionRuleStore()
        await store.addToolGrant(toolName: "write_file", ownerAccountID: owner, strictTenancy: true)
        #expect(await store.isGranted(.ownerToolName(ownerAccountID: owner, toolName: "write_file")))
        await store.removeToolGrant(toolName: "write_file", ownerAccountID: owner, strictTenancy: true)
        #expect(await store.isGranted(.ownerToolName(ownerAccountID: owner, toolName: "write_file")) == false)
    }

    @Test("legacy stored grant matches canonical tool name at runtime")
    func legacyStoredGrantMatchesCanonical() async {
        let store = InMemoryPermissionRuleStore(rules: [.toolName("read")])
        #expect(await store.isGranted(.toolName("read_file")))
        #expect(await store.grantedToolNames(ownerAccountID: nil, strictTenancy: false) == ["read_file"])
    }

    @Test("addToolGrant persists canonical tool name")
    func addToolGrantPersistsCanonical() async {
        let store = InMemoryPermissionRuleStore()
        await store.addToolGrant(toolName: "read", ownerAccountID: nil, strictTenancy: false)
        #expect(await store.list() == [.toolName("read_file")])
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
        let scope = ExecApprovalScope(conversationID: UUID(), ownerAccountID: nil)
        await store.registerPending(id: "p1", command: "git push origin main", scope: scope)
        _ = await store.resolve(
            id: "p1",
            scope: scope,
            strictTenancy: false,
            ownerScope: nil,
            approved: true,
            durable: true
        )
        #expect(await rules.isGranted(.commandName("git")))
        #expect(await store.isDurableApproved(command: "git status"))
    }

    @Test("grantedToolRules includes toolRule and legacy commandName bridge")
    func grantedToolRulesBridge() async {
        let owner = UUID()
        let store = InMemoryPermissionRuleStore()
        await store.add(.toolRule(.argumentMatcher(toolName: "bash", pattern: "npm run *"), ownerAccountID: owner))
        await store.add(.commandName("git"))
        let rules = await store.grantedToolRules(ownerAccountID: owner, strictTenancy: true)
        #expect(rules.contains(.argumentMatcher(toolName: "bash", pattern: "npm run *")))
        #expect(rules.contains(.argumentMatcher(toolName: "bash", pattern: "git")))
    }
}
