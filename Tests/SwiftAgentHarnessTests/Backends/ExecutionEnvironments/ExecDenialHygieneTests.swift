import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ExecApprovalCommandEquivalence")
struct ExecApprovalCommandEquivalenceTests {
    @Test("normalize collapses internal whitespace")
    func normalizeWhitespace() {
        #expect(ExecApprovalCommandEquivalence.normalize("npm  test") == "npm test")
        #expect(ExecApprovalCommandEquivalence.matches("npm  test", "npm test"))
    }

    @Test("different commands do not match")
    func differentCommands() {
        #expect(!ExecApprovalCommandEquivalence.matches("npm test", "npm install"))
    }

    @Test("trimmed edges match")
    func trimmedEdges() {
        #expect(ExecApprovalCommandEquivalence.matches("  npm test  ", "npm test"))
    }
}

@Suite("ExecDenialHygiene")
struct ExecDenialHygieneTests {
    private func makeModel() -> Model {
        HarnessConversationTestFixtures.makeTestModel(name: "denial-hygiene")
    }

    private func bashAssistantAndResult(
        command: String,
        toolCallID: String,
        resultContent: String
    ) -> [Message] {
        let base = Date()
        return [
            Message(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: base,
                toolCalls: [
                    ToolCall(
                        name: "bash",
                        arguments: .object(["command": .string(command)]),
                        id: toolCallID
                    ),
                ]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: resultContent,
                timestamp: base.addingTimeInterval(1),
                toolCalls: [],
                toolCallId: toolCallID
            ),
        ]
    }

    @Test("deny clears prior matching bash tool result")
    func denyClearsPriorMatchingResult() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let persistenceDomain = ConversationPersistenceDomain.makeForTesting(
            container: container,
            logger: nil,
            harnessSessionPersistenceOverride: harness
        )
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: harness
        )
        let model = makeModel()
        let conversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: runtimeSession,
            model: model,
            extraMessages: bashAssistantAndResult(
                command: "npm test",
                toolCallID: "tc-deny-1",
                resultContent: "PASS 42 tests"
            )
        )

        let hygiene = ExecDenialHygieneService(
            persistenceDomain: persistenceDomain,
            refreshProjection: { _ in }
        )
        let store = ExecApprovalStore(denialHygieneHandler: hygiene)
        let scope = ExecApprovalScope(conversationID: conversationID, ownerAccountID: nil)
        await store.registerPending(id: "ap-1", command: "npm test", scope: scope)
        let resolution = await store.resolve(
            id: "ap-1",
            scope: scope,
            strictTenancy: false,
            ownerScope: nil,
            approved: false,
            reason: "denied"
        )
        #expect(resolution == .denied("denied"))

        let placeholder = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
        let active = try ConversationTranscriptLineage.activeMessages(
            conversationID: conversationID,
            harness: harness
        )
        let toolMessage = try #require(active.first { $0.role == .tool })
        #expect(toolMessage.content == placeholder)
    }

    @Test("deny leaves unrelated command tool results intact")
    func denyLeavesUnrelatedResults() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let persistenceDomain = ConversationPersistenceDomain.makeForTesting(
            container: container,
            logger: nil,
            harnessSessionPersistenceOverride: harness
        )
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: harness
        )
        let model = makeModel()
        let conversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: runtimeSession,
            model: model,
            extraMessages: bashAssistantAndResult(
                command: "npm install",
                toolCallID: "tc-other",
                resultContent: "added 10 packages"
            )
        )

        let hygiene = ExecDenialHygieneService(
            persistenceDomain: persistenceDomain,
            refreshProjection: { _ in }
        )
        let store = ExecApprovalStore(denialHygieneHandler: hygiene)
        let scope = ExecApprovalScope(conversationID: conversationID, ownerAccountID: nil)
        await store.registerPending(id: "ap-2", command: "npm test", scope: scope)
        _ = await store.resolve(
            id: "ap-2",
            scope: scope,
            strictTenancy: false,
            ownerScope: nil,
            approved: false
        )

        let active = try ConversationTranscriptLineage.activeMessages(
            conversationID: conversationID,
            harness: harness
        )
        let toolMessage = try #require(active.first { $0.role == .tool })
        #expect(toolMessage.content == "added 10 packages")
    }

    @Test("already cleared results are idempotent")
    func idempotentOnAlreadyCleared() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let persistenceDomain = ConversationPersistenceDomain.makeForTesting(
            container: container,
            logger: nil,
            harnessSessionPersistenceOverride: harness
        )
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: harness
        )
        let model = makeModel()
        let placeholder = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
        let conversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: runtimeSession,
            model: model,
            extraMessages: bashAssistantAndResult(
                command: "npm test",
                toolCallID: "tc-cleared",
                resultContent: placeholder
            )
        )

        let hygiene = ExecDenialHygieneService(
            persistenceDomain: persistenceDomain,
            refreshProjection: { _ in }
        )
        await hygiene.poisonPriorMatchingToolResults(
            conversationID: conversationID,
            deniedCommand: "npm test",
            excludingToolCallId: nil
        )

        let events = await persistenceDomain.conversationEventsWithFrontier(conversationID: conversationID).0
        #expect(!events.contains { $0.kind == ConversationEventKind.toolResultTrimCheckpoint.rawValue })
    }

    @Test("deny resolution succeeds when hygiene persistence is unavailable")
    func denySucceedsWhenHygieneFails() async throws {
        let store = ExecApprovalStore(
            denialHygieneHandler: ExecDenialHygieneService(
                persistenceDomain: ConversationPersistenceDomain.makeForTesting(
                    container: try HarnessConversationTestFixtures.makeInMemoryContainer(),
                    logger: nil
                ),
                refreshProjection: { _ in }
            )
        )
        let scope = ExecApprovalScope(conversationID: UUID(), ownerAccountID: nil)
        await store.registerPending(id: "ap-3", command: "npm test", scope: scope)
        let resolution = await store.resolve(
            id: "ap-3",
            scope: scope,
            strictTenancy: false,
            ownerScope: nil,
            approved: false
        )
        #expect(resolution == .denied("denied"))
    }

    @Test("deny emits tool result trim checkpoint when clearing")
    func denyEmitsToolResultTrimCheckpoint() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let persistenceDomain = ConversationPersistenceDomain.makeForTesting(
            container: container,
            logger: nil,
            harnessSessionPersistenceOverride: harness
        )
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: harness
        )
        let model = makeModel()
        let conversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: runtimeSession,
            model: model,
            extraMessages: bashAssistantAndResult(
                command: "npm test",
                toolCallID: "tc-checkpoint",
                resultContent: "ok"
            )
        )

        let hygiene = ExecDenialHygieneService(
            persistenceDomain: persistenceDomain,
            refreshProjection: { _ in }
        )
        await hygiene.poisonPriorMatchingToolResults(
            conversationID: conversationID,
            deniedCommand: "npm test",
            excludingToolCallId: nil
        )

        let events = await persistenceDomain.conversationEventsWithFrontier(conversationID: conversationID).0
        #expect(events.contains { $0.kind == ConversationEventKind.toolResultTrimCheckpoint.rawValue })
        #expect(events.contains { $0.kind == ConversationEventKind.checkpointInvalidated.rawValue })
    }
}
