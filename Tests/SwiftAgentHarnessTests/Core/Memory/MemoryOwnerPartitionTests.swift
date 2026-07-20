import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Memory owner partition")
struct MemoryOwnerPartitionTests {
    private let strictTenancy = TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)

    @Test("strict tenancy resolves distinct project and user dirs per owner")
    func ownerScopedPathsDifferByOwner() throws {
        let ownerA = UUID()
        let ownerB = UUID()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-partition-\(UUID().uuidString)", isDirectory: true)
            .path

        let projectA = try AgentMemoryPathResolver.resolveMemoryDirectory(
            canonicalGitRoot: workspace,
            cwd: workspace,
            ownerAccountID: ownerA,
            tenancyPolicy: strictTenancy
        )
        let projectB = try AgentMemoryPathResolver.resolveMemoryDirectory(
            canonicalGitRoot: workspace,
            cwd: workspace,
            ownerAccountID: ownerB,
            tenancyPolicy: strictTenancy
        )
        let userA = try AgentMemoryPathResolver.resolveUserMemoryDirectory(
            ownerAccountID: ownerA,
            tenancyPolicy: strictTenancy
        )
        let userB = try AgentMemoryPathResolver.resolveUserMemoryDirectory(
            ownerAccountID: ownerB,
            tenancyPolicy: strictTenancy
        )

        #expect(projectA != projectB)
        #expect(userA != userB)
        #expect(projectA.path.contains("/owners/\(AgentMemoryPathResolver.ownerSegment(ownerA))/"))
        #expect(userB.path.contains("/owners/\(AgentMemoryPathResolver.ownerSegment(ownerB))/memory/user"))
    }

    @Test("non-strict tenancy ignores owner for path layout")
    func nonStrictPathsIgnoreOwner() throws {
        let ownerA = UUID()
        let ownerB = UUID()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-partition-loose-\(UUID().uuidString)", isDirectory: true)
            .path

        let projectA = try AgentMemoryPathResolver.resolveMemoryDirectory(
            canonicalGitRoot: workspace,
            cwd: workspace,
            ownerAccountID: ownerA,
            tenancyPolicy: .disabled
        )
        let projectB = try AgentMemoryPathResolver.resolveMemoryDirectory(
            canonicalGitRoot: workspace,
            cwd: workspace,
            ownerAccountID: ownerB,
            tenancyPolicy: .disabled
        )
        let userA = try AgentMemoryPathResolver.resolveUserMemoryDirectory(
            ownerAccountID: ownerA,
            tenancyPolicy: .disabled
        )
        let userB = try AgentMemoryPathResolver.resolveUserMemoryDirectory(
            ownerAccountID: ownerB,
            tenancyPolicy: .disabled
        )

        #expect(projectA == projectB)
        #expect(userA == userB)
        #expect(!projectA.path.contains("/owners/"))
    }

    @Test("strict tenancy fails closed when owner is missing")
    func strictTenancyRequiresOwner() async throws {
        let service = DefaultMemoryService(
            config: .default,
            tenancyPolicy: strictTenancy
        )
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-partition-fail-\(UUID().uuidString)", isDirectory: true)
            .path

        await #expect(throws: MemoryPathValidationError.ownerAccountIDRequiredUnderStrictTenancy) {
            try await service.makeSessionContext(
                conversationID: UUID(),
                cwd: workspace,
                ownerAccountID: nil
            )
        }
    }

    @Test("project memory written by one owner is not visible to another owner on the same workspace")
    func projectMemoryIsolationAcrossOwners() async throws {
        let service = DefaultMemoryService(
            config: .default,
            tenancyPolicy: strictTenancy
        )
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let ownerA = UUID()
        let ownerB = UUID()
        let contextA = try await service.makeSessionContext(
            conversationID: UUID(),
            cwd: workspace.path,
            ownerAccountID: ownerA
        )
        let contextB = try await service.makeSessionContext(
            conversationID: UUID(),
            cwd: workspace.path,
            ownerAccountID: ownerB
        )
        _ = try await service.bootstrapSession(context: contextA)

        let storeA = AgentMemoryStore(memoryDirectory: contextA.memoryDirectory)
        try storeA.ensureLayout()
        try storeA.writeTopic(
            filename: "private_fact.md",
            content: """
            ---
            name: Private fact
            description: owner A only
            type: project
            ---
            Secret from owner A
            """
        )

        let storeB = AgentMemoryStore(memoryDirectory: contextB.memoryDirectory)
        let search = HybridMemorySearch()
        let hits = await search.search(
            query: "Secret from owner A",
            memoryDirectory: contextB.memoryDirectory,
            limit: 5
        )
        #expect(hits.isEmpty)
        #expect(storeB.listTopicFilenames().isEmpty)
    }

    @Test("user-tier manifest entries are isolated per owner store")
    func userTierManifestIsolationAcrossOwners() async throws {
        let backend = FileStoreMemoryBackend(config: .default)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-tier-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownerA = UUID()
        let ownerB = UUID()
        let conversationA = UUID()
        let conversationB = UUID()
        let contextA = MemorySessionContext(
            conversationID: conversationA,
            cwd: root.path,
            canonicalGitRoot: root.path,
            memoryDirectory: root.appendingPathComponent("a/project/memory", isDirectory: true),
            userMemoryDirectory: root.appendingPathComponent("a/user", isDirectory: true),
            ownerAccountID: ownerA
        )
        let contextB = MemorySessionContext(
            conversationID: conversationB,
            cwd: root.path,
            canonicalGitRoot: root.path,
            memoryDirectory: root.appendingPathComponent("b/project/memory", isDirectory: true),
            userMemoryDirectory: root.appendingPathComponent("b/user", isDirectory: true),
            ownerAccountID: ownerB
        )

        try await backend.initialize(sessionID: conversationA, context: contextA)
        try await backend.initialize(sessionID: conversationB, context: contextB)

        let userStoreA = AgentMemoryStore(
            memoryDirectory: contextA.userMemoryDirectory,
            indexCapProfile: .user
        )
        try userStoreA.ensureLayout()
        try userStoreA.writeTopic(
            filename: "prefs.md",
            content: """
            ---
            name: Prefs
            description: concise answers
            type: user
            ---
            Owner A prefers terse replies.
            """
        )

        let entriesA = await backend.manifestEntries(conversationID: conversationA)
        let entriesB = await backend.manifestEntries(conversationID: conversationB)
        #expect(entriesA.contains { $0.filename == "prefs.md" && $0.tierScope == .user })
        #expect(!entriesB.contains { $0.filename == "prefs.md" })
    }

    @Test("dreaming bridge discovers owner-scoped memory directories")
    func dreamingDiscoversOwnerScopedDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-owner-\(UUID().uuidString)", isDirectory: true)
        let ownersRoot = root.appendingPathComponent("owners", isDirectory: true)
        let ownerID = UUID()
        let memoryDir = ownersRoot
            .appendingPathComponent(AgentMemoryPathResolver.ownerSegment(ownerID), isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("proj-key", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try "index".write(
            to: memoryDir.appendingPathComponent("MEMORY.md"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = MemoryDreamingBridge(
            config: .default,
            projectsRoot: root.appendingPathComponent("projects", isDirectory: true),
            ownersRoot: ownersRoot
        )
        let discovered = bridge.discoverMemoryDirectories()
        #expect(discovered.map(\.standardizedFileURL).contains(memoryDir.standardizedFileURL))
    }
}
