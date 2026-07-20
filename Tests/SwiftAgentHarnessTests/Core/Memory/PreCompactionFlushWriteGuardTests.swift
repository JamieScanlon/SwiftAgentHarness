import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PreCompactionFlushWriteGuard")
struct PreCompactionFlushWriteGuardTests {
    private let policy = PreCompactionFlushWriteGuard.Policy(manifestTopicFilenames: ["existing.md"])

    private let validTopic = """
---
name: Topic
description: hook line
type: user
---
Body content.
"""

    @Test("rejects daily staging write_file")
    func rejectsDailyWrite() {
        let result = PreCompactionFlushWriteGuard.validateWriteFile(
            basename: "2026-07-10.md",
            content: validTopic,
            policy: policy
        )
        guard case .failure(.dailyStagingForbidden) = result else {
            Issue.record("expected dailyStagingForbidden, got \(result)")
            return
        }
    }

    @Test("rejects write_file to MEMORY.md")
    func rejectsMemoryIndexWriteFile() {
        let result = PreCompactionFlushWriteGuard.validateWriteFile(
            basename: "MEMORY.md",
            content: "- [T](t.md) — hook",
            policy: policy
        )
        guard case .failure(.memoryIndexWriteFileForbidden) = result else {
            Issue.record("expected memoryIndexWriteFileForbidden, got \(result)")
            return
        }
    }

    @Test("rejects write_file overwriting existing manifest topic")
    func rejectsExistingTopicWriteFile() {
        let result = PreCompactionFlushWriteGuard.validateWriteFile(
            basename: "existing.md",
            content: validTopic,
            policy: policy
        )
        guard case .failure(.existingTopicWriteFileForbidden) = result else {
            Issue.record("expected existingTopicWriteFileForbidden, got \(result)")
            return
        }
    }

    @Test("allows write_file for new topic with frontmatter")
    func allowsNewTopicWriteFile() {
        let result = PreCompactionFlushWriteGuard.validateWriteFile(
            basename: "new-topic.md",
            content: validTopic,
            policy: policy
        )
        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test("allows append-only edit to existing topic")
    func allowsExistingTopicAppendEdit() {
        let prior = validTopic
        let appended = prior + "\n\nMore durable facts."
        let result = PreCompactionFlushWriteGuard.validateEditFile(
            basename: "existing.md",
            priorContent: prior,
            newContent: appended,
            policy: policy
        )
        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test("rejects non-append edit to existing topic")
    func rejectsExistingTopicReplaceEdit() {
        let result = PreCompactionFlushWriteGuard.validateEditFile(
            basename: "existing.md",
            priorContent: validTopic,
            newContent: validTopic.replacingOccurrences(of: "Body", with: "Replaced"),
            policy: policy
        )
        guard case .failure(.existingTopicEditNotAppendOnly) = result else {
            Issue.record("expected existingTopicEditNotAppendOnly, got \(result)")
            return
        }
    }

    @Test("allows append-only MEMORY.md index line edit")
    func allowsMemoryIndexAppendEdit() {
        let prior = "# Index\n"
        let newContent = prior + "- [Topic](new-topic.md) — durable hook\n"
        let result = PreCompactionFlushWriteGuard.validateEditFile(
            basename: "MEMORY.md",
            priorContent: prior,
            newContent: newContent,
            policy: policy
        )
        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test("rejects MEMORY.md body replacement edit")
    func rejectsMemoryIndexReplaceEdit() {
        let result = PreCompactionFlushWriteGuard.validateEditFile(
            basename: "MEMORY.md",
            priorContent: "# Index\n- [A](a.md) — old\n",
            newContent: "paragraph dump instead of index",
            policy: policy
        )
        guard case .failure(.memoryIndexEditNotAppendOnly) = result else {
            Issue.record("expected memoryIndexEditNotAppendOnly, got \(result)")
            return
        }
    }

    @Test("curatedTopicBasenames filters daily and MEMORY.md paths")
    func curatedTopicBasenamesFilter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flush-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try validTopic.write(to: dir.appendingPathComponent("good.md"), atomically: true, encoding: .utf8)
        try "daily".write(to: dir.appendingPathComponent("2026-07-10.md"), atomically: true, encoding: .utf8)
        try "index".write(to: dir.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let paths: Set<String> = [
            dir.appendingPathComponent("good.md").path,
            dir.appendingPathComponent("2026-07-10.md").path,
            dir.appendingPathComponent("MEMORY.md").path,
        ]
        let basenames = PreCompactionFlushWriteGuard.curatedTopicBasenames(
            fromAbsolutePaths: paths,
            memoryDirectory: dir
        )
        #expect(basenames == ["good.md"])
    }
}
