import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Skills directory resolver")
struct SkillsDirectoryResolverTests {
    @Test("relative path resolves under workspace root")
    func relativePath() {
        let workspace = "/tmp/project"
        let resolved = SkillsDirectoryResolver.resolve(workspaceRoot: workspace, configuredPath: "skills")
        #expect(resolved?.path == "/tmp/project/skills")
    }

    @Test("absolute path resolves as-is")
    func absolutePath() {
        let resolved = SkillsDirectoryResolver.resolve(workspaceRoot: "/tmp/project", configuredPath: "/var/skills")
        #expect(resolved?.path == "/var/skills")
    }

    @Test("empty or nil path returns nil")
    func emptyPath() {
        #expect(SkillsDirectoryResolver.resolve(workspaceRoot: "/tmp", configuredPath: nil) == nil)
        #expect(SkillsDirectoryResolver.resolve(workspaceRoot: "/tmp", configuredPath: "  ") == nil)
    }
}
