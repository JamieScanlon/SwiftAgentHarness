import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

private struct CheckpointSuiteTransformer: ConversationTransforming {
    func transformContext(_ input: ContextTransformInput) async throws -> ContextTransformOutput {
        let provenance = input.messages.prefix(1).map { message in
            ContextTransformMessageProvenance(
                transformedMessageID: message.id,
                origin: .synthesized,
                sourceMessageIDs: [message.id]
            )
        }
        return ContextTransformOutput(
            messages: input.messages,
            diagnostics: "checkpoint_suite_context",
            messageProvenance: provenance
        )
    }

    func transformToolResult(_ input: ToolResultTransformInput) async throws -> ToolResultTransformOutput {
        ToolResultTransformOutput(
            result: ToolResult(
                success: input.result.success,
                content: "[trimmed] \(input.result.content)",
                metadata: input.result.metadata,
                toolCallId: input.result.toolCallId
            ),
            diagnostics: "checkpoint_suite_tool"
        )
    }

    func transformTurnSummary(_ input: TurnSummaryTransformInput) async throws -> TurnSummaryTransformOutput {
        TurnSummaryTransformOutput(replacementTurnMessages: input.turnMessages, diagnostics: nil)
    }
}

@Suite("Checkpoint production suite runtime coverage", .serialized)
struct CheckpointProductionSuiteTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel(name: String = "checkpoint-suite-test") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func transformConfig() -> ConversationTransformConfiguration {
        let d = ConversationTransformConfiguration.default
        var cc = d.contextCompaction
        cc.enabled = false
        return ConversationTransformConfiguration(
            chat: d.chat,
            plan: d.plan,
            agent: d.agent,
            transformTimeoutSeconds: d.transformTimeoutSeconds,
            contextCompaction: cc
        )
    }

    @Test("Runtime emits memory injection snapshot checkpoint from synthesized context provenance")
    func runtimePersistsMemoryInjectionCheckpoint() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: transformConfig(),
            conversationTransformer: CheckpointSuiteTransformer()
        )
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: runtimeSession)
        let model = makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversation = try #require(await runtimeSession.currentConversation())

        let memorySeed = Message(
            id: UUID(),
            role: .user,
            content: "checkpoint suite memory seed",
            timestamp: Date(),
            toolCalls: []
        )
        await runtimeSession.appendMessagesToConversation([memorySeed], conversationID: conversation.id)
        let refreshed = try #require(await conversationAPI.apiGetConversation(id: conversation.id))

        _ = await runtimeSession.contextProjectionService.transformedContextMessages(
            from: refreshed.messages,
            conversation: refreshed,
            phase: .initial
        )

        let checkpoint = await conversationAPI.apiGetLatestCheckpoint(
            conversationID: conversation.id,
            kind: HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue
        )
        let required = try #require(checkpoint)
        #expect(required.kind == HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue)
        guard case .memoryInjectionSnapshot(let wire) = required.checkpoint else {
            Issue.record("expected memory-injection checkpoint payload")
            return
        }
        #expect(!wire.injectionFingerprint.isEmpty)
        #expect(!wire.snapshotJSON.isEmpty)
        #expect(!wire.scopeMessageIDs.isEmpty)
    }

    @Test("Runtime emits tool-result-trim checkpoint when tool result transform synthesizes output")
    func runtimePersistsToolResultTrimCheckpoint() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: transformConfig(),
            conversationTransformer: CheckpointSuiteTransformer()
        )
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: runtimeSession)
        let model = makeModel(name: "checkpoint-suite-tools")
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversation = try #require(await runtimeSession.currentConversation())

        let toolCallID = "tc-checkpoint-suite"
        let call = ToolCall(name: "web-fetch", arguments: .object([:]), id: toolCallID)
        let transformed = await runtimeSession.conversationMessagingRuntimeService.applyToolResultTransform(
            toolCall: call,
            result: ToolResult(success: true, content: "raw-result", metadata: .object([:]), toolCallId: toolCallID),
            conversationID: conversation.id
        )
        let toolMessage = Message(
            id: UUID(),
            role: .tool,
            content: transformed.content,
            timestamp: Date(),
            toolCallId: toolCallID
        )
        await runtimeSession.appendMessagesToConversation([toolMessage], conversationID: conversation.id)

        let checkpoint = await conversationAPI.apiGetLatestCheckpoint(
            conversationID: conversation.id,
            kind: HarnessCheckpointWireKind.toolResultTrim.rawValue
        )
        let required = try #require(checkpoint)
        #expect(required.kind == HarnessCheckpointWireKind.toolResultTrim.rawValue)
        guard case .toolResultTrim(let wire) = required.checkpoint else {
            Issue.record("expected tool-result-trim checkpoint payload")
            return
        }
        #expect(wire.trimmedToolCallIds.contains(toolCallID))
        #expect(wire.coveredMessageIDs.contains(toolMessage.id))
        #expect(wire.configFingerprint == ToolResultTrimCheckpointPolicy.configFingerprint)
    }
}
