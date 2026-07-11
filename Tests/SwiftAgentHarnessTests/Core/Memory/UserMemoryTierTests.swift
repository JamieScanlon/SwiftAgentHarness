import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("User memory tier")
struct UserMemoryTierTests {
    @Test("resolveUserMemoryDirectory lives under config home and differs from project memory")
    func userMemoryDirectoryPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-tier-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let userDir = try AgentMemoryPathResolver.resolveUserMemoryDirectory()
        let projectDir = try AgentMemoryPathResolver.resolveMemoryDirectory(
            canonicalGitRoot: root.path,
            cwd: root.path
        )

        #expect(userDir.path.contains("/memory/user"))
        #expect(FileManager.default.fileExists(atPath: userDir.path))
        #expect(userDir.standardizedFileURL != projectDir.standardizedFileURL)
    }

    @Test("user-tier index truncates at tighter caps")
    func userTierIndexTruncation() {
        let lines = (1...60).map { "- [Item \($0)](item\($0).md) — hook \($0)" }.joined(separator: "\n")
        let result = MemoryIndexTruncator.truncateUserTier(lines)
        #expect(result.text.contains("truncated"))
        #expect(result.text.contains("line cap (50)"))
    }

    @Test("tiered memory path resolver routes user prefix and bare filenames")
    func tieredMemoryPathResolver() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiered-project-\(UUID().uuidString)", isDirectory: true)
        let user = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiered-user-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: user)
        }

        let projectPath = try PathPolicy.resolveTieredMemoryRelativePath(
            raw: "prefs.md",
            projectMemoryDirectory: project,
            userMemoryDirectory: user,
            requireExists: false
        )
        let userPath = try PathPolicy.resolveTieredMemoryRelativePath(
            raw: "user/prefs.md",
            projectMemoryDirectory: project,
            userMemoryDirectory: user,
            requireExists: false
        )
        #expect(projectPath.hasSuffix("/prefs.md"))
        #expect(userPath.hasSuffix("/prefs.md"))
        #expect(projectPath != userPath)

        #expect(throws: Error.self) {
            _ = try PathPolicy.resolveTieredMemoryRelativePath(
                raw: "user/../escape.md",
                projectMemoryDirectory: project,
                userMemoryDirectory: user,
                requireExists: false
            )
        }
    }

    @Test("extraction prompt includes user-tier write routing")
    func extractionPromptIncludesUserTierRouting() {
        let prompt = MemoryExtractionPrompts.systemPrompt(manifestLines: [])
        #expect(prompt.contains("## User vs project tier (write routing)"))
        #expect(prompt.contains("user/MEMORY.md"))
        #expect(prompt.contains("Prefix paths with `user/`"))
    }

    @Test("combined index places user tier before project tier")
    func combinedIndexOrdering() throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-project-\(UUID().uuidString)", isDirectory: true)
        let userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-user-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: projectDir)
            try? FileManager.default.removeItem(at: userDir)
        }

        let userStore = AgentMemoryStore(memoryDirectory: userDir, indexCapProfile: .user)
        _ = try userStore.writeIndex(content: "- [Prefs](prefs.md) — concise answers")
        let projectStore = AgentMemoryStore(memoryDirectory: projectDir)
        _ = try projectStore.writeIndex(content: "- [Repo](repo.md) — integration tests")

        let context = MemorySessionContext(
            conversationID: UUID(),
            cwd: projectDir.deletingLastPathComponent().path,
            canonicalGitRoot: nil,
            memoryDirectory: projectDir,
            userMemoryDirectory: userDir
        )
        let builder = FileStoreMemoryPromptBuilder(config: .default)
        let sections = try builder.buildPromptSections(
            context: context,
            store: projectStore,
            recalled: "",
            availableToolNames: []
        )
        #expect(sections.memoryIndexText.contains("# User memory index [scope:user]"))
        #expect(sections.memoryIndexText.contains("# Agent memory index [scope:project]"))
        let userRange = sections.memoryIndexText.range(of: "# User memory index")!
        let projectRange = sections.memoryIndexText.range(of: "# Agent memory index")!
        #expect(userRange.lowerBound < projectRange.lowerBound)
        #expect(sections.taxonomyPromptText.contains("## User vs project tier (write routing)"))
    }

    @Test("extractionManifestLines tags user and project scopes")
    func extractionManifestLinesScoped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let conversationID = UUID()
        let context = try service.makeSessionContext(conversationID: conversationID, cwd: root.path)
        _ = try await service.bootstrapSession(context: context)

        let userDir = context.userMemoryDirectory
        let userTopic = userDir.appendingPathComponent("global-prefs.md")
        try """
        ---
        name: Global Prefs
        description: Always concise
        type: user
        ---
        Prefers short answers.
        """.write(to: userTopic, atomically: true, encoding: .utf8)

        let projectTopic = context.memoryDirectory.appendingPathComponent("repo-note.md")
        try """
        ---
        name: Repo Note
        description: Project fact
        type: project
        ---
        Uses Postgres.
        """.write(to: projectTopic, atomically: true, encoding: .utf8)

        let lines = await service.extractionManifestLines(conversationID: conversationID)
        #expect(lines.contains { $0.contains("[scope:user]") && $0.contains("global-prefs.md") })
        #expect(lines.contains { $0.contains("[scope:project]") && $0.contains("repo-note.md") })
    }

    @Test("manifestEntries merges user tier before project tier with tierScope")
    func manifestEntriesMergedOrdering() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-merge-\(UUID().uuidString)", isDirectory: true)
        let userDir = root.appendingPathComponent("user-tier", isDirectory: true)
        let projectDir = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = DefaultMemoryService(userConfigDir: root.appendingPathComponent("cfg", isDirectory: true))
        let conversationID = UUID()
        let context = MemorySessionContext(
            conversationID: conversationID,
            cwd: root.path,
            canonicalGitRoot: root.path,
            memoryDirectory: projectDir,
            userMemoryDirectory: userDir
        )
        _ = try await service.bootstrapSession(context: context)

        try """
        ---
        name: Global
        description: concise
        type: user
        ---
        Body
        """.write(to: userDir.appendingPathComponent("aaa-user.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: Repo
        description: postgres
        type: project
        ---
        Body
        """.write(to: projectDir.appendingPathComponent("zzz-project.md"), atomically: true, encoding: .utf8)

        let entries = await service.manifestEntries(conversationID: conversationID)
        #expect(entries.count == 2)
        #expect(entries[0].tierScope == .user)
        #expect(entries[0].filename == "aaa-user.md")
        #expect(entries[1].tierScope == .project)
        #expect(entries[1].filename == "zzz-project.md")
    }

    @Test("recallForTurn surfaces user-tier topics with scope tags and nearest-wins ordering")
    func recallLayeringScopeTagsAndOrdering() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-layer-\(UUID().uuidString)", isDirectory: true)
        let userDir = root.appendingPathComponent("user-tier", isDirectory: true)
        let projectDir = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = DefaultMemoryService(userConfigDir: root.appendingPathComponent("cfg", isDirectory: true))
        let conversationID = UUID()
        let context = MemorySessionContext(
            conversationID: conversationID,
            cwd: root.path,
            canonicalGitRoot: root.path,
            memoryDirectory: projectDir,
            userMemoryDirectory: userDir
        )
        _ = try await service.bootstrapSession(context: context)

        try """
        ---
        name: Global Prefs
        description: concise answers preferred
        type: user
        ---
        User prefers concise answers.
        """.write(to: userDir.appendingPathComponent("prefs.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: Repo Style
        description: verbose logging preferred
        type: project
        ---
        This repo prefers verbose logging.
        """.write(to: projectDir.appendingPathComponent("prefs.md"), atomically: true, encoding: .utf8)

        let manifest = await service.manifestEntries(conversationID: conversationID)
        let recall = try await service.recallForTurn(
            request: MemoryRecallRequest(
                session: context,
                userQuery: "concise verbose logging preferred",
                manifestEntries: manifest
            )
        )
        #expect(recall.selectedFilenames.contains("user/prefs.md"))
        #expect(recall.selectedFilenames.contains("prefs.md"))
        #expect(recall.recalledBodiesText.contains("[scope:user]"))
        #expect(recall.recalledBodiesText.contains("[scope:project]"))
        let userScope = recall.recalledBodiesText.range(of: "[scope:user]")!
        let projectScope = recall.recalledBodiesText.range(of: "[scope:project]")!
        #expect(userScope.lowerBound < projectScope.lowerBound)
    }

    @Test("LLM selector parseFilenames accepts user-tier selection keys")
    func llmSelectorParsesUserPrefixedKeys() {
        let allowed: Set<String> = ["prefs.md", "user/global.md"]
        let parsed = ModelPoolMemoryLLMRecallSelector.parseFilenames(
            from: #"{"filenames":["user/global.md","prefs.md","unknown.md"]}"#,
            allowed: allowed
        )
        #expect(parsed == ["user/global.md", "prefs.md"])
    }
}
