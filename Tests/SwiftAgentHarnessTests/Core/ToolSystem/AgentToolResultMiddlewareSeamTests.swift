import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

/// Coverage for CR-D: the eager LLM tool-result summarizer was removed; the runtime-delivery
/// tool-result seam is now a deterministic, host-registerable middleware
/// (`registerAgentToolResultMiddleware`). The `tool_result_trim` checkpoint plumbing is retained
/// but dormant unless a content-rewriting middleware is mounted.
@Suite("Agent tool-result middleware seam", .serialized)
struct AgentToolResultMiddlewareSeamTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel(name: String = "agent-tool-result-seam") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("Host middleware reshapes a tool result before the model sees it")
    func seamRewritesToolResult() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container)
        await runtimeSession.orchestratorRuntimeService.registerAgentToolResultMiddleware(
            AgentToolResultMiddleware(id: "seam-rewrite") { _, result in
                ToolResult(
                    success: result.success,
                    content: "[shaped] \(result.content)",
                    metadata: result.metadata,
                    toolCallId: result.toolCallId
                )
            }
        )
        let model = makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversation = try #require(await runtimeSession.currentConversation())

        let call = ToolCall(name: "web-fetch", arguments: .object([:]), id: "tc-seam-1")
        let transformed = await runtimeSession.conversationMessagingRuntimeService.applyToolResultTransform(
            toolCall: call,
            result: ToolResult(success: true, content: "raw", metadata: .object([:]), toolCallId: "tc-seam-1"),
            conversationID: conversation.id
        )
        #expect(transformed.content == "[shaped] raw")
    }

    @Test("No middleware leaves a large tool result unmodified (no LLM summarization)")
    func passthroughWhenNoMiddleware() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container)
        let model = makeModel(name: "agent-tool-result-passthrough")
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversation = try #require(await runtimeSession.currentConversation())

        // Well above the former 1k summarization threshold, well under the 120k runtime cap.
        let large = String(repeating: "x", count: 20_000)
        let call = ToolCall(name: "web-fetch", arguments: .object([:]), id: "tc-pass-1")
        let transformed = await runtimeSession.conversationMessagingRuntimeService.applyToolResultTransform(
            toolCall: call,
            result: ToolResult(success: true, content: large, metadata: .object([:]), toolCallId: "tc-pass-1"),
            conversationID: conversation.id
        )
        #expect(transformed.content == large)
    }

    @Test("Trim checkpoint stays dormant when no content-rewriting middleware is mounted")
    func dormantTrimCheckpointWithoutMiddleware() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container)
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: runtimeSession)
        let model = makeModel(name: "agent-tool-result-dormant")
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversation = try #require(await runtimeSession.currentConversation())

        let toolCallID = "tc-dormant-1"
        let call = ToolCall(name: "web-fetch", arguments: .object([:]), id: toolCallID)
        let transformed = await runtimeSession.conversationMessagingRuntimeService.applyToolResultTransform(
            toolCall: call,
            result: ToolResult(success: true, content: "raw-result", metadata: .object([:]), toolCallId: toolCallID),
            conversationID: conversation.id
        )
        #expect(transformed.content == "raw-result")
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
        #expect(checkpoint == nil)
    }
}
