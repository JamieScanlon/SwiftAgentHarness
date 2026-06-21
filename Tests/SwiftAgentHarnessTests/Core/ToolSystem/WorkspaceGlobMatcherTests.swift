import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Workspace glob matcher")
struct WorkspaceGlobMatcherTests {
    @Test("star matches single path segment")
    func starMatchesSegment() {
        #expect(WorkspaceGlobMatcher.matches(relativePath: "foo.ts", pattern: "*.ts"))
        #expect(!WorkspaceGlobMatcher.matches(relativePath: "src/foo.ts", pattern: "*.ts"))
    }

    @Test("globstar matches nested paths")
    func globstarMatchesNested() {
        #expect(WorkspaceGlobMatcher.matches(relativePath: "src/foo.ts", pattern: "src/**/*.ts"))
        #expect(WorkspaceGlobMatcher.matches(relativePath: "src/nested/bar.ts", pattern: "src/**/*.ts"))
        #expect(!WorkspaceGlobMatcher.matches(relativePath: "lib/foo.ts", pattern: "src/**/*.ts"))
    }

    @Test("question mark matches single character")
    func questionMarkMatchesOne() {
        #expect(WorkspaceGlobMatcher.matches(relativePath: "a.txt", pattern: "?.txt"))
        #expect(!WorkspaceGlobMatcher.matches(relativePath: "ab.txt", pattern: "?.txt"))
    }

    @Test("bare star matches any file path")
    func bareStarMatchesAll() {
        #expect(WorkspaceGlobMatcher.matches(relativePath: "deep/nested/file.txt", pattern: "*"))
    }

    @Test("path segment case is preserved in matching")
    func casePreservedInPath() {
        #expect(WorkspaceGlobMatcher.matches(relativePath: "Src/Foo.ts", pattern: "Src/*.ts"))
        #expect(!WorkspaceGlobMatcher.matches(relativePath: "src/foo.ts", pattern: "Src/*.ts"))
    }
}
