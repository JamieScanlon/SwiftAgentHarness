import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Mode profile project config directory resolver")
struct ModeProfileProjectConfigDirectoryResolverTests {
    @Test("Default project mode config directory lands under application support")
    func defaultDirectoryLandsUnderApplicationSupport() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let resolution = ModeProfileProjectConfigDirectoryResolver.resolve(cwd: workspace.path)

        let directory = try #require(resolution.directory)
        #expect(directory.path.contains("/projects/"))
        #expect(directory.lastPathComponent == "mode-profiles")
        #expect(!PathPolicy.isPathInsideRoot(directory.path, root: workspace.path))
        #expect(resolution.diagnostics.isEmpty)
    }

    @Test("Project mode config directory inside workspace is rejected")
    func directoryInsideWorkspaceIsRejected() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let insideWorkspace = workspace.appendingPathComponent("mode-profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: insideWorkspace, withIntermediateDirectories: true)

        let resolution = HarnessEnvironmentOverride.$overrides.withValue([
            ModeProfileProjectConfigDirectoryResolver.overrideEnvKey: insideWorkspace.path,
        ]) {
            ModeProfileProjectConfigDirectoryResolver.resolve(cwd: workspace.path)
        }

        #expect(resolution.directory == nil)
        #expect(resolution.diagnostics.contains("project mode config directory rejected: inside agent write scope"))
    }

    @Test("Explicit external project mode config directory is accepted")
    func externalDirectoryIsAccepted() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-profile-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }

        let resolution = HarnessEnvironmentOverride.$overrides.withValue([
            ModeProfileProjectConfigDirectoryResolver.overrideEnvKey: external.path,
        ]) {
            ModeProfileProjectConfigDirectoryResolver.resolve(cwd: workspace.path)
        }

        #expect(resolution.directory?.standardizedFileURL.path == external.standardizedFileURL.path)
        #expect(resolution.diagnostics.isEmpty)
    }
}
