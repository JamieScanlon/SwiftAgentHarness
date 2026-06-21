import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Workspace path policy")
struct WorkspacePathPolicyTests {
    private func makeFixture() throws -> (workspace: URL, memory: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsp-policy-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let memory = base.appendingPathComponent("memory", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "inside".write(to: workspace.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        return (workspace, memory, outside)
    }

    private func cleanup(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    @Test("read rejects absolute path outside workspace")
    func readRejectsAbsoluteOutside() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        #expect(throws: WorkspaceFilesystemError.outsideAllowedRoots) {
            try WorkspacePathPolicy.resolveReadablePath(
                raw: "/etc/passwd",
                workspaceRoot: fixture.workspace.path,
                memoryDirectory: fixture.memory,
                memoryWriteOnly: false
            )
        }
    }

    @Test("read rejects relative escape")
    func readRejectsRelativeEscape() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        #expect(throws: WorkspaceFilesystemError.outsideAllowedRoots) {
            try WorkspacePathPolicy.resolveReadablePath(
                raw: "../outside/secret.txt",
                workspaceRoot: fixture.workspace.path,
                memoryDirectory: fixture.memory,
                memoryWriteOnly: false
            )
        }
    }

    @Test("read allows workspace file")
    func readAllowsWorkspaceFile() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        let path = try WorkspacePathPolicy.resolveReadablePath(
            raw: "inside.txt",
            workspaceRoot: fixture.workspace.path,
            memoryDirectory: fixture.memory,
            memoryWriteOnly: false
        )
        #expect(path.hasSuffix("inside.txt"))
    }

    @Test("read allows memory directory file in normal mode")
    func readAllowsMemoryFile() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        try "mem".write(to: fixture.memory.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let path = try WorkspacePathPolicy.resolveReadablePath(
            raw: fixture.memory.appendingPathComponent("note.md").path,
            workspaceRoot: fixture.workspace.path,
            memoryDirectory: fixture.memory,
            memoryWriteOnly: false
        )
        #expect(path.hasSuffix("note.md"))
    }

    @Test("memory-write-only denies workspace read")
    func memoryWriteOnlyDeniesWorkspaceRead() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        #expect(throws: WorkspaceFilesystemError.writeDenied) {
            try WorkspacePathPolicy.resolveReadablePath(
                raw: "inside.txt",
                workspaceRoot: fixture.workspace.path,
                memoryDirectory: fixture.memory,
                memoryWriteOnly: true
            )
        }
    }

    @Test("write rejects path outside workspace")
    func writeRejectsOutside() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        #expect(throws: WorkspaceFilesystemError.outsideAllowedRoots) {
            try WorkspacePathPolicy.resolveWritablePath(
                raw: fixture.outside.appendingPathComponent("evil.txt").path,
                workspaceRoot: fixture.workspace.path,
                memoryDirectory: fixture.memory,
                memoryWriteOnly: false
            )
        }
    }

    @Test("write rejects symlink escape")
    func writeRejectsSymlinkEscape() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        let link = fixture.workspace.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.outside.appendingPathComponent("secret.txt")
        )
        do {
            _ = try WorkspacePathPolicy.resolveWritablePath(
                raw: link.path,
                workspaceRoot: fixture.workspace.path,
                memoryDirectory: fixture.memory,
                memoryWriteOnly: false
            )
            Issue.record("Expected symlink escape rejection")
        } catch let error as WorkspaceFilesystemError {
            #expect(error == .symlinkEscape || error == .outsideAllowedRoots)
        }
    }

    @Test("grep search root rejects traversal")
    func grepSearchRootRejectsTraversal() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        #expect(throws: WorkspaceFilesystemError.outsideAllowedRoots) {
            try WorkspacePathPolicy.resolveSearchRoot(
                raw: "../../outside",
                workspaceRoot: fixture.workspace.path,
                memoryDirectory: fixture.memory,
                memoryWriteOnly: false
            )
        }
    }

    @Test("grep search root allows workspace subdirectory")
    func grepSearchRootAllowsSubdirectory() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        let sub = fixture.workspace.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let root = try WorkspacePathPolicy.resolveSearchRoot(
            raw: "sub",
            workspaceRoot: fixture.workspace.path,
            memoryDirectory: fixture.memory,
            memoryWriteOnly: false
        )
        #expect(root == sub.path)
    }

    @Test("memory relative path rejects traversal in filename")
    func memoryRelativeRejectsTraversal() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        #expect(throws: WorkspaceFilesystemError.invalidPath) {
            try WorkspacePathPolicy.resolveMemoryRelativePath(
                raw: "../../outside/secret.txt",
                memoryDirectory: fixture.memory,
                requireExists: false
            )
        }
    }

    @Test("memory relative path resolves existing topic file")
    func memoryRelativeResolvesTopic() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        try "topic".write(to: fixture.memory.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let path = try WorkspacePathPolicy.resolveMemoryRelativePath(
            raw: "note.md",
            memoryDirectory: fixture.memory,
            requireExists: true
        )
        #expect(path.hasSuffix("note.md"))
    }

    @Test("memory relative path defaults require file exists")
    func memoryRelativeRequiresExists() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        #expect(throws: WorkspaceFilesystemError.self) {
            try WorkspacePathPolicy.resolveMemoryRelativePath(
                raw: "missing.md",
                memoryDirectory: fixture.memory,
                requireExists: true
            )
        }
    }

    @Test("symlink chain depth 5 resolves")
    func symlinkChainDepth5() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        let target = fixture.memory.appendingPathComponent("note.md")
        try "mem".write(to: target, atomically: true, encoding: .utf8)
        var prior = target
        for i in 0..<5 {
            let link = fixture.memory.appendingPathComponent("hop\(i)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: prior)
            prior = link
        }
        let path = try WorkspacePathPolicy.resolveMemoryRelativePath(
            raw: "hop4",
            memoryDirectory: fixture.memory,
            requireExists: true
        )
        #expect(path.hasSuffix("note.md"))
    }

    @Test("resolveExistingPath enforces max symlink depth")
    func resolveExistingPathMaxDepth() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace, fixture.memory, fixture.outside) }
        let target = fixture.memory.appendingPathComponent("note.md")
        try "mem".write(to: target, atomically: true, encoding: .utf8)
        var prior = target
        for i in 0..<5 {
            let link = fixture.memory.appendingPathComponent("hop\(i)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: prior)
            prior = link
        }
        do {
            _ = try WorkspacePathPolicy.resolveExistingPathForTesting(
                fixture.memory.appendingPathComponent("hop4").path,
                maxSymlinkDepth: 3
            )
            Issue.record("Expected symlink loop when max depth exceeded")
        } catch let error as WorkspaceFilesystemError {
            #expect(error == .symlinkLoop)
        }
    }

    @Test("workspace root symlink resolves readable path to real directory")
    func workspaceSymlinkRootAlignment() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsp-symlink-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try "inside".write(to: real.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        let path = try WorkspacePathPolicy.resolveReadablePath(
            raw: "inside.txt",
            workspaceRoot: link.path,
            memoryDirectory: nil,
            memoryWriteOnly: false
        )
        #expect(path.hasSuffix("inside.txt"))
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
