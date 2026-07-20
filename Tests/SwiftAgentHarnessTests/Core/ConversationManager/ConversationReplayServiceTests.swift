import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationReplayService")
struct ConversationReplayServiceTests {
    private func makeFixture() throws -> (
        deps: ConversationRuntimeDependencies,
        services: HarnessRuntimeSessionFactory.Services,
        recording: RecordingConversationMessagingPort,
        replay: ConversationReplayService
    ) {
        let (deps, _) = try ReplayProjectionTestSupport.makeReplayProjectionDependencies()
        let services = ReplayProjectionTestSupport.makeReplayProjectionServices(deps: deps)
        let recording = RecordingConversationMessagingPort()
        let replay = ReplayProjectionTestSupport.makeReplayService(
            deps: deps,
            messaging: recording,
            services: services
        )
        return (deps, services, recording, replay)
    }

    private func message(
        role: MessageRole,
        content: String,
        timestamp: Date,
        toolCallId: String? = nil,
        toolCalls: [ToolCall] = []
    ) -> Message {
        Message(
            id: UUID(),
            role: role,
            content: content,
            timestamp: timestamp,
            toolCalls: toolCalls,
            toolCallId: toolCallId
        )
    }

    @Test("startConversationReplay throws when source conversation is missing")
    func startReplaySourceNotFound() async throws {
        let (_, _, _, replay) = try makeFixture()
        let missingID = UUID()
        await #expect(throws: ConversationServiceError.conversationNotFound) {
            try await replay.startConversationReplay(sourceConversationID: missingID)
        }
    }

    @Test("startConversationReplay rejects when replay is already active")
    func startReplayAlreadyRunning() async throws {
        let (deps, _, _, replay) = try makeFixture()
        let base = Date()
        var bulk: [Message] = []
        for index in 0..<10 {
            bulk.append(message(role: .user, content: "u\(index)", timestamp: base.addingTimeInterval(Double(index * 2))))
            bulk.append(message(role: .assistant, content: "a\(index)", timestamp: base.addingTimeInterval(Double(index * 2 + 1))))
        }
        let sourceID = try await ReplayProjectionTestSupport.seedConversation(deps: deps, extraMessages: bulk)
        try await replay.startConversationReplay(sourceConversationID: sourceID)
        defer { Task { await replay.stopConversationReplay(conversationID: sourceID) } }
        await #expect(throws: ConversationServiceError.conversationReplayAlreadyRunning) {
            try await replay.startConversationReplay(sourceConversationID: sourceID)
        }
    }

    @Test("turn finalization runs once after assistant when next message is user")
    func turnFinalizationOnAssistantBeforeUser() async throws {
        let (deps, _, recording, replay) = try makeFixture()
        let base = Date()
        let transcript = [
            message(role: .user, content: "u0", timestamp: base),
            message(role: .assistant, content: "a0", timestamp: base.addingTimeInterval(1)),
            message(role: .user, content: "u1", timestamp: base.addingTimeInterval(2)),
        ]
        let sourceID = try await ReplayProjectionTestSupport.seedConversation(deps: deps, extraMessages: transcript)
        try await replay.startConversationReplay(sourceConversationID: sourceID)
        let finished = await ReplayProjectionTestSupport.waitUntil({
            await replay.testing_hasActiveReplayTasks() == false
        })
        #expect(finished)
        #expect(await recording.turnSummaryCalls.count == 1)
    }

    @Test("turn finalization runs once at end of transcript")
    func turnFinalizationAtEndOfTranscript() async throws {
        let (deps, _, recording, replay) = try makeFixture()
        let base = Date()
        let transcript = [
            message(role: .user, content: "u0", timestamp: base),
            message(role: .assistant, content: "a0", timestamp: base.addingTimeInterval(1)),
        ]
        let sourceID = try await ReplayProjectionTestSupport.seedConversation(deps: deps, extraMessages: transcript)
        try await replay.startConversationReplay(sourceConversationID: sourceID)
        let finished = await ReplayProjectionTestSupport.waitUntil({
            await replay.testing_hasActiveReplayTasks() == false
        })
        #expect(finished)
        #expect(await recording.turnSummaryCalls.count == 1)
    }

    @Test("turn finalization skips between consecutive assistant messages")
    func turnFinalizationSkipsBetweenAssistants() async throws {
        let (deps, _, recording, replay) = try makeFixture()
        let base = Date()
        let transcript = [
            message(role: .user, content: "u0", timestamp: base),
            message(role: .assistant, content: "a0", timestamp: base.addingTimeInterval(1)),
            message(role: .assistant, content: "a1", timestamp: base.addingTimeInterval(2)),
        ]
        let sourceID = try await ReplayProjectionTestSupport.seedConversation(deps: deps, extraMessages: transcript)
        try await replay.startConversationReplay(sourceConversationID: sourceID)
        let finished = await ReplayProjectionTestSupport.waitUntil({
            await replay.testing_hasActiveReplayTasks() == false
        })
        #expect(finished)
        #expect(await recording.turnSummaryCalls.count == 1)
    }

    @Test("stopConversationReplay cancels active replay task")
    func stopReplayCancelsActiveTask() async throws {
        let (deps, _, _, replay) = try makeFixture()
        let base = Date()
        var bulk: [Message] = []
        for index in 0..<10 {
            bulk.append(message(role: .user, content: "u\(index)", timestamp: base.addingTimeInterval(Double(index * 2))))
            bulk.append(message(role: .assistant, content: "a\(index)", timestamp: base.addingTimeInterval(Double(index * 2 + 1))))
        }
        let sourceID = try await ReplayProjectionTestSupport.seedConversation(deps: deps, extraMessages: bulk)
        try await replay.startConversationReplay(sourceConversationID: sourceID)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await replay.stopConversationReplay(conversationID: sourceID)
        let stopped = await ReplayProjectionTestSupport.waitUntil({
            await replay.testing_hasActiveReplayTasks() == false
        })
        #expect(stopped)
        #expect(await replay.isConversationReplayActive(conversationID: sourceID) == false)
    }

    @Test("finalizeReplaySandbox deletes sandbox and refreshes source projection")
    func finalizeReplaySandboxRestoresSource() async throws {
        let (deps, _, recording, replay) = try makeFixture()
        let base = Date()
        let transcript = [
            message(role: .user, content: "u0", timestamp: base),
            message(role: .assistant, content: "a0", timestamp: base.addingTimeInterval(1)),
        ]
        let sourceID = try await ReplayProjectionTestSupport.seedConversation(deps: deps, extraMessages: transcript)
        try await replay.startConversationReplay(sourceConversationID: sourceID)
        let finished = await ReplayProjectionTestSupport.waitUntil({
            await replay.testing_hasActiveReplayTasks() == false
        })
        #expect(finished)
        let appendCalls = await recording.appendCalls
        guard let sandboxID = appendCalls.first?.conversationID else {
            Issue.record("expected sandbox append during replay")
            return
        }
        #expect(sandboxID != sourceID)
        let deleteCalls = await recording.deleteCalls
        let refreshCalls = await recording.refreshCalls
        #expect(deleteCalls.contains(sandboxID))
        #expect(refreshCalls.contains { $0.conversationID == sourceID })
    }

    @Test("isConversationReplayActive resolves both source and sandbox IDs while running")
    func activeReplayResolvesSourceAndSandboxIDs() async throws {
        let (deps, _, recording, replay) = try makeFixture()
        let base = Date()
        var bulk: [Message] = []
        for index in 0..<8 {
            bulk.append(message(role: .user, content: "u\(index)", timestamp: base.addingTimeInterval(Double(index * 2))))
            bulk.append(message(role: .assistant, content: "a\(index)", timestamp: base.addingTimeInterval(Double(index * 2 + 1))))
        }
        let sourceID = try await ReplayProjectionTestSupport.seedConversation(deps: deps, extraMessages: bulk)
        try await replay.startConversationReplay(sourceConversationID: sourceID)
        defer { Task { await replay.stopConversationReplay(conversationID: sourceID) } }
        let sawActive = await ReplayProjectionTestSupport.waitUntil({
            guard await replay.testing_hasActiveReplayTasks() else { return false }
            let appendCalls = await recording.appendCalls
            guard let sandboxID = appendCalls.first?.conversationID else { return false }
            let sourceActive = await replay.isConversationReplayActive(conversationID: sourceID)
            let sandboxActive = await replay.isConversationReplayActive(conversationID: sandboxID)
            return sourceActive && sandboxActive
        })
        #expect(sawActive)
    }

    @Test("startConversationReplay creates distinct sandbox conversation in registry")
    func sandboxConversationSeededInRegistry() async throws {
        let (deps, _, recording, replay) = try makeFixture()
        let base = Date()
        let transcript = [
            message(role: .user, content: "u0", timestamp: base),
            message(role: .assistant, content: "a0", timestamp: base.addingTimeInterval(1)),
        ]
        let sourceID = try await ReplayProjectionTestSupport.seedConversation(deps: deps, extraMessages: transcript)
        try await replay.startConversationReplay(sourceConversationID: sourceID)
        let sawSandbox = await ReplayProjectionTestSupport.waitUntil({
            let appendCalls = await recording.appendCalls
            guard let sandboxID = appendCalls.first?.conversationID else { return false }
            guard sandboxID != sourceID else { return false }
            return await deps.persistenceDomain.modelConversation(id: sandboxID) != nil
        })
        #expect(sawSandbox)
        await replay.stopConversationReplay(conversationID: sourceID)
    }
}
