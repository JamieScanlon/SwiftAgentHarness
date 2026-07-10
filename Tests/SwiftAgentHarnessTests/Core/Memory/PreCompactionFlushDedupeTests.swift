import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("PreCompactionFlushDedupe")
struct PreCompactionFlushDedupeTests {
    private func message(id: UUID = UUID(), content: String) -> Message {
        Message(id: id, role: .user, content: content, timestamp: Date(), toolCalls: [])
    }

    @Test("middle fingerprint is stable for identical messages")
    func fingerprintStability() {
        let id = UUID()
        let messages = [message(id: id, content: "hello")]
        let first = PreCompactionFlushMiddleFingerprint.of(messages: messages)
        let second = PreCompactionFlushMiddleFingerprint.of(messages: messages)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("middle fingerprint changes when content or order changes")
    func fingerprintSensitivity() {
        let a = message(content: "alpha")
        let b = message(content: "beta")
        let hashAB = PreCompactionFlushMiddleFingerprint.of(messages: [a, b])
        let hashBA = PreCompactionFlushMiddleFingerprint.of(messages: [b, a])
        let hashChanged = PreCompactionFlushMiddleFingerprint.of(messages: [message(content: "alpha")])
        #expect(hashAB != hashBA)
        #expect(hashAB != hashChanged)
    }

    @Test("dedupe state filters overlapping middle to novel message IDs")
    func filterNovelMiddle() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        var state = PreCompactionFlushDedupeState()
        state.recordSuccessfulFlush(middle: [
            message(id: id1, content: "one"),
            message(id: id2, content: "two"),
        ])
        let novel = state.filterNovelMiddle([
            message(id: id1, content: "one"),
            message(id: id2, content: "two"),
            message(id: id3, content: "three"),
        ])
        #expect(novel.count == 1)
        #expect(novel.first?.id == id3)
    }

    @Test("dedupe state returns empty when full middle already flushed")
    func filterEmptyWhenFullyFlushed() {
        let id1 = UUID()
        var state = PreCompactionFlushDedupeState()
        let middle = [message(id: id1, content: "done")]
        state.recordSuccessfulFlush(middle: middle)
        let novel = state.filterNovelMiddle(middle)
        #expect(novel.isEmpty)
    }

    @Test("dedupe state skips duplicate middle fingerprint")
    func fingerprintSkip() {
        let middle = [message(content: "same segment")]
        var state = PreCompactionFlushDedupeState()
        let fingerprint = PreCompactionFlushMiddleFingerprint.of(messages: middle)
        state.recordSuccessfulFlush(middle: middle)
        let skip = state.shouldSkipFingerprint(fingerprint)
        #expect(skip)
    }

    @Test("DefaultMemoryService clearPreCompactionFlushCycle resets flushed IDs")
    func serviceCycleReset() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flush-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = DefaultMemoryService(userConfigDir: dir.appendingPathComponent("user", isDirectory: true))
        let conversationID = UUID()
        let id1 = UUID()
        let middle = [
            Message(id: id1, role: .user, content: "fact", timestamp: Date(), toolCalls: []),
        ]
        await service.recordPreCompactionFlushMiddle(conversationID: conversationID, middle: middle)
        #expect(await service.filterPreCompactionFlushMiddle(conversationID: conversationID, middle: middle).isEmpty)
        await service.clearPreCompactionFlushCycle(conversationID: conversationID)
        #expect(await service.filterPreCompactionFlushMiddle(conversationID: conversationID, middle: middle).count == 1)
        try? FileManager.default.removeItem(at: dir)
    }
}
