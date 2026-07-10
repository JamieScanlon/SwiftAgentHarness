import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("PreCompressProviderNotes")
struct PreCompressProviderNotesTests {
    private actor OnPreCompressCallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private struct StubMemoryProvider: MemoryProviding {
        let note: String
        let counter: OnPreCompressCallCounter?

        init(note: String, counter: OnPreCompressCallCounter? = nil) {
            self.note = note
            self.counter = counter
        }

        func initialize(sessionID: UUID, context: MemorySessionContext) async throws {
            _ = sessionID
            _ = context
        }

        func systemPromptBlock() async -> String { "" }

        func prefetch(query: String) async -> String? {
            _ = query
            return nil
        }

        func queuePrefetch(query: String) async {
            _ = query
        }

        func syncTurn(userContent: String, assistantContent: String) async {
            _ = userContent
            _ = assistantContent
        }

        func onPreCompress(messages: [String]) async -> String {
            _ = messages
            if let counter { await counter.increment() }
            return note
        }

        func onSessionEnd(messages: [String]) async {
            _ = messages
        }

        func shutdown() async {}
    }

    @Test("collect joins non-empty provider notes in stable order")
    func collectAggregatesMultipleProviders() async {
        let providers: [any MemoryProviding] = [
            StubMemoryProvider(note: "  builtin note  "),
            StubMemoryProvider(note: "external note"),
        ]
        let aggregated = await MemoryProviderPreCompressNotes.collect(
            providers: providers,
            messages: ["msg"]
        )
        #expect(aggregated == "builtin note\n\nexternal note")
    }

    @Test("collect skips empty and whitespace-only provider notes")
    func collectSkipsEmptyNotes() async {
        let providers: [any MemoryProviding] = [
            StubMemoryProvider(note: ""),
            StubMemoryProvider(note: "   \n  "),
            StubMemoryProvider(note: "kept"),
        ]
        let aggregated = await MemoryProviderPreCompressNotes.collect(
            providers: providers,
            messages: []
        )
        #expect(aggregated == "kept")
    }

    @Test("summarizerHandoffBlock renders fenced block when notes are present")
    func summarizerHandoffBlockNonEmpty() {
        let block = MemoryProviderPreCompressNotes.summarizerHandoffBlock(notes: "User prefers dark mode.")
        #expect(block.contains("# Memory provider pre-compaction extraction"))
        #expect(block.contains("<memory-pre-compress>"))
        #expect(block.contains("User prefers dark mode."))
        #expect(block.contains("</memory-pre-compress>"))
    }

    @Test("summarizerHandoffBlock is empty when notes are absent")
    func summarizerHandoffBlockEmpty() {
        #expect(MemoryProviderPreCompressNotes.summarizerHandoffBlock(notes: nil).isEmpty)
        #expect(MemoryProviderPreCompressNotes.summarizerHandoffBlock(notes: "  ").isEmpty)
    }

    @Test("DefaultMemoryService collectProviderPreCompressNotes uses active providers")
    func serviceCollectsFromRegisteredExternalProvider() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("precompress-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = DefaultMemoryService(userConfigDir: dir.appendingPathComponent("user", isDirectory: true))
        try await service.registerExternalMemoryProvider(
            id: "test-external",
            provider: StubMemoryProvider(note: "External durable fact.")
        )
        let notes = await service.collectProviderPreCompressNotes(messages: ["turn transcript"])
        #expect(notes == "External durable fact.")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("runPreCompactionFlush does not invoke provider onPreCompress")
    func flushDoesNotCallOnPreCompress() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("precompress-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let memoryDir = dir.appendingPathComponent("memory", isDirectory: true)
        let counter = OnPreCompressCallCounter()
        let service = DefaultMemoryService(userConfigDir: dir.appendingPathComponent("user", isDirectory: true))
        try await service.registerExternalMemoryProvider(
            id: "counting",
            provider: StubMemoryProvider(note: "should not run during flush", counter: counter)
        )
        let conversationID = UUID()
        let context = MemorySessionContext(
            conversationID: conversationID,
            cwd: dir.path,
            canonicalGitRoot: dir.path,
            memoryDirectory: memoryDir
        )
        _ = try await service.bootstrapSession(context: context)
        let port = MemorySubAgentSpawnPort(
            spawnBlockingRecall: { _, _, _, _, _ in nil },
            spawnBackgroundExtraction: { _ in },
            spawnBlockingPreCompactionFlush: { _, _, _ in true }
        )
        await service.bindSpawnPort(port)
        let middle = [Message(id: UUID(), role: .user, content: "msg", timestamp: Date(), toolCalls: [])]
        _ = await service.runPreCompactionFlush(
            context: PreCompactionMemoryFlushContext(
                conversationID: conversationID,
                middleMessages: middle,
                maxFlushedMemoryEntries: 8,
                timeoutMs: 1000
            ),
            spawnPort: port,
            logger: nil
        )
        #expect(await counter.count == 0)
        _ = await service.collectProviderPreCompressNotes(messages: ["msg"])
        #expect(await counter.count == 1)
        try? FileManager.default.removeItem(at: dir)
    }
}
