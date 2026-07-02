import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ExecutablePathResolver")
struct ExecutablePathResolverTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-exec-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(named name: String, in directory: URL) throws -> String {
        let path = directory.appendingPathComponent(name).path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test("bare name resolves via PATH")
    func bareNameOnPath() throws {
        let binDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: binDir) }
        let expected = try writeExecutable(named: "sah-tool", in: binDir)
        let resolved = ExecutablePathResolver.resolve(
            "sah-tool",
            path: binDir.path,
            cwd: nil
        )
        #expect(resolved == expected)
    }

    @Test("bare name returns nil when not on PATH")
    func bareNameMissing() {
        let resolved = ExecutablePathResolver.resolve(
            "sah-definitely-missing-tool",
            path: "/nonexistent/bin",
            cwd: nil
        )
        #expect(resolved == nil)
    }

    @Test("absolute executable path resolves")
    func absolutePath() throws {
        let binDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: binDir) }
        let expected = try writeExecutable(named: "sah-abs", in: binDir)
        let resolved = ExecutablePathResolver.resolve(
            expected,
            path: nil,
            cwd: nil
        )
        #expect(resolved == expected)
    }

    @Test("relative path resolves against cwd")
    func relativePath() throws {
        let workDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let binDir = workDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let expected = try writeExecutable(named: "sah-rel", in: binDir)
        let resolved = ExecutablePathResolver.resolve(
            "./bin/sah-rel",
            path: nil,
            cwd: workDir.path
        )
        #expect(resolved == expected)
    }

    @Test("default PATH fallback when path is nil")
    func defaultPathFallback() {
        let resolved = ExecutablePathResolver.resolve(
            "true",
            path: nil,
            cwd: nil,
            fileManager: FileManager.default
        )
        #expect(resolved != nil)
        #expect(FileManager.default.isExecutableFile(atPath: resolved!))
    }
}
