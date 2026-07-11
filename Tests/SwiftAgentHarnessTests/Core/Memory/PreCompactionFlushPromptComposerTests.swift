import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PreCompactionFlushPromptComposer")
struct PreCompactionFlushPromptComposerTests {
    @Test("default prompt includes enforced three-hint block")
    func defaultPromptIncludesEnforcedHints() {
        let prompt = MemoryPreCompactionFlushPrompts.systemPrompt(manifestLines: [])
        #expect(prompt.contains("## Non-negotiable flush constraints"))
        #expect(prompt.contains("### Target (curated promotion only)"))
        #expect(prompt.contains("### Append-only"))
        #expect(prompt.contains("### Read-only scope"))
        #expect(prompt.contains("Do NOT write daily staging"))
        #expect(prompt.contains("curated promotion only"))
        #expect(prompt.contains("two steps"))
        #expect(prompt.contains("memory directory"))
        #expect(prompt.contains("## Memory vs skills (routing)"))
        #expect(prompt.contains("Do **not** save procedures as memory"))
    }

    @Test("custom body is preserved and enforced hints still appended")
    func customBodyWithEnforcedHints() {
        let custom = "Operator task: promote only surprising durable facts from the transcript."
        let prompt = MemoryPreCompactionFlushPrompts.systemPrompt(
            manifestLines: ["[user] note.md (2026-07-10): hook"],
            customBody: custom
        )
        #expect(prompt.contains(custom))
        #expect(prompt.contains("[user] note.md"))
        #expect(prompt.contains("## Non-negotiable flush constraints"))
        #expect(prompt.contains("### Target (curated promotion only)"))
        #expect(!prompt.contains("You promote durable cross-session memories"))
    }

    @Test("contradictory custom body still receives target prohibition")
    func contradictoryCustomBodyStillGetsTargetHint() {
        let custom = "URGENT: append everything to today's daily staging file YYYY-MM-DD.md."
        let prompt = MemoryPreCompactionFlushPrompts.systemPrompt(manifestLines: [], customBody: custom)
        #expect(prompt.contains(custom))
        #expect(prompt.contains("Do NOT write daily staging"))
    }

    @Test("custom prompt loader returns nil for missing path")
    func loaderMissingPath() {
        #expect(PreCompactionFlushCustomPromptLoader.load(path: nil) == nil)
        #expect(PreCompactionFlushCustomPromptLoader.load(path: "") == nil)
        #expect(
            PreCompactionFlushCustomPromptLoader.load(
                path: "/tmp/does-not-exist-\(UUID().uuidString).md"
            ) == nil
        )
    }

    @Test("custom prompt loader reads file content")
    func loaderReadsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flush-custom-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("flush-prompt.md")
        let body = "Custom operator flush guidance only."
        try body.write(to: file, atomically: true, encoding: .utf8)
        #expect(PreCompactionFlushCustomPromptLoader.load(path: file.path) == body)
    }

    @Test("configuration loader round-trips preCompactionFlushSystemPromptPath")
    func configurationLoaderRoundTrip() {
        let loaded = MemoryConfigurationLoader.load(fromMemoryObject: [
            "preCompactionFlushSystemPromptPath": "/etc/harness/flush-prompt.md",
        ])
        #expect(loaded.preCompactionFlushSystemPromptPath == "/etc/harness/flush-prompt.md")
        let empty = MemoryConfigurationLoader.load(fromMemoryObject: [
            "preCompactionFlushSystemPromptPath": "",
        ])
        #expect(empty.preCompactionFlushSystemPromptPath == nil)
    }

    @Test("preCompactionFlushConstraintsPrompt aliases enforced block")
    func constraintsPromptAlias() {
        #expect(MemoryTypeTaxonomy.preCompactionFlushConstraintsPrompt == PreCompactionFlushSafetyHints.enforcedBlock())
    }
}
