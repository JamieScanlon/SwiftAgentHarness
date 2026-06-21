import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ContextCompactionToolProvider")
struct ContextCompactionToolProviderTests {

    /// Records calls to `performManualCompaction` and returns a configured result. Used in
    /// place of `HarnessRuntimeSession` so the tool provider can be tested in isolation.
    private actor StubPerformer: ContextCompactionPerforming {
        struct CapturedCall: Sendable {
            let conversationID: UUID
            let trigger: ContextCompactionManualTrigger
            let reason: String?
        }

        private(set) var calls: [CapturedCall] = []
        private let resultFactory: @Sendable (CapturedCall) -> Result<ContextCompactionManualResult, Error>

        init(_ resultFactory: @escaping @Sendable (CapturedCall) -> Result<ContextCompactionManualResult, Error>) {
            self.resultFactory = resultFactory
        }

        func performManualCompaction(
            conversationID: UUID,
            trigger: ContextCompactionManualTrigger,
            reason: String?
        ) async throws -> ContextCompactionManualResult {
            let captured = CapturedCall(conversationID: conversationID, trigger: trigger, reason: reason)
            calls.append(captured)
            switch resultFactory(captured) {
            case .success(let r):
                return r
            case .failure(let e):
                throw e
            }
        }

        func capturedCalls() -> [CapturedCall] { calls }
    }

    private static func makeMessages(count: Int) -> [Message] {
        (0..<count).map { i in
            Message(
                id: UUID(),
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "msg-\(i)",
                timestamp: Date(),
                toolCalls: []
            )
        }
    }

    private static func successResult(
        conversationID: UUID,
        trigger: ContextCompactionManualTrigger,
        promptTokens: Int = 5_000,
        thresholdTokens: Int = 4_000
    ) -> ContextCompactionManualResult {
        let originals = makeMessages(count: 8)
        let compacted = makeMessages(count: 2)
        return ContextCompactionManualResult(
            trigger: trigger,
            conversationID: conversationID,
            originalMessages: originals,
            compactedMessages: compacted,
            diagnostics: "context_compacted",
            messageProvenance: nil,
            noopReason: nil,
            refusalReason: nil,
            persisted: true,
            promptTokens: promptTokens,
            thresholdTokens: thresholdTokens
        )
    }

    private static func refusalResult(
        conversationID: UUID,
        trigger: ContextCompactionManualTrigger,
        promptTokens: Int = 100,
        thresholdTokens: Int = 1_000
    ) -> ContextCompactionManualResult {
        let originals = makeMessages(count: 4)
        return ContextCompactionManualResult(
            trigger: trigger,
            conversationID: conversationID,
            originalMessages: originals,
            compactedMessages: nil,
            diagnostics: nil,
            messageProvenance: nil,
            noopReason: nil,
            refusalReason: "Refused: conversation is below 50% of compaction threshold (100 / 1000 tokens; gate 500).",
            persisted: false,
            promptTokens: promptTokens,
            thresholdTokens: thresholdTokens
        )
    }

    private static func noopResult(
        conversationID: UUID,
        trigger: ContextCompactionManualTrigger,
        reason: String = "context_compaction_gated_cooldown_or_min_chars",
        promptTokens: Int = 5_000,
        thresholdTokens: Int = 4_000
    ) -> ContextCompactionManualResult {
        let originals = makeMessages(count: 4)
        return ContextCompactionManualResult(
            trigger: trigger,
            conversationID: conversationID,
            originalMessages: originals,
            compactedMessages: nil,
            diagnostics: nil,
            messageProvenance: nil,
            noopReason: reason,
            refusalReason: nil,
            persisted: false,
            promptTokens: promptTokens,
            thresholdTokens: thresholdTokens
        )
    }

    private static func makeToolCall(
        conversationID: UUID? = nil,
        rawConversationID: String? = nil,
        reason: String? = nil
    ) -> ToolCall {
        var args: [String: JSON] = [:]
        if let raw = rawConversationID {
            args["conversation_id"] = .string(raw)
        } else if let conversationID {
            args["conversation_id"] = .string(conversationID.uuidString)
        }
        if let reason {
            args["reason"] = .string(reason)
        }
        return ToolCall(name: "compact_conversation", arguments: .object(args), id: "tc-\(UUID().uuidString)")
    }

    /// JSON helpers — `EasyJSON.JSON` is not Equatable (associated-value enum), so use
    /// pattern-matching extractors when asserting metadata payloads.
    private static func bool(_ json: JSON?) -> Bool? {
        if case .boolean(let v) = json { return v }
        return nil
    }

    private static func string(_ json: JSON?) -> String? {
        if case .string(let v) = json { return v }
        return nil
    }

    private static func integer(_ json: JSON?) -> Int? {
        if case .integer(let v) = json { return v }
        return nil
    }

    @Test("Tool returns success when performer reports a persisted compaction")
    func successPath() async throws {
        let conversationID = UUID()
        let stub = StubPerformer { call in
            .success(Self.successResult(conversationID: call.conversationID, trigger: call.trigger))
        }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let result = try await provider.executeTool(Self.makeToolCall(conversationID: conversationID))
        #expect(result.success)
        #expect(result.content.contains("Compacted conversation"))
        #expect(result.content.contains("8 → 2 messages"))
        if case .object(let metadata) = result.metadata {
            #expect(Self.bool(metadata["persisted"]) == true)
            #expect(Self.integer(metadata["originalMessageCount"]) == 8)
            #expect(Self.integer(metadata["compactedMessageCount"]) == 2)
            #expect(Self.integer(metadata["promptTokens"]) == 5_000)
        } else {
            Issue.record("Expected metadata object")
        }

        let calls = await stub.capturedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.trigger == .modelTool)
        #expect(calls.first?.reason == nil)
    }

    @Test("Refusal from gate surfaces as success=false with refusal reason in content")
    func refusalSurfacesAsToolResultFalse() async throws {
        let conversationID = UUID()
        let stub = StubPerformer { call in
            .success(Self.refusalResult(conversationID: call.conversationID, trigger: call.trigger))
        }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let result = try await provider.executeTool(Self.makeToolCall(conversationID: conversationID))
        #expect(!result.success)
        #expect(result.content.lowercased().contains("refused"))
        if case .object(let metadata) = result.metadata {
            #expect(Self.bool(metadata["refused"]) == true)
            #expect(Self.integer(metadata["promptTokens"]) == 100)
            #expect(Self.integer(metadata["thresholdTokens"]) == 1_000)
        } else {
            Issue.record("Expected metadata object")
        }
    }

    @Test("Noop (cooldown or transform-disabled) surfaces as success=false with noopReason")
    func noopSurfacesAsToolResultFalse() async throws {
        let conversationID = UUID()
        let stub = StubPerformer { call in
            .success(Self.noopResult(conversationID: call.conversationID, trigger: call.trigger))
        }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let result = try await provider.executeTool(Self.makeToolCall(conversationID: conversationID))
        #expect(!result.success)
        if case .object(let metadata) = result.metadata {
            #expect(Self.string(metadata["noopReason"]) == "context_compaction_gated_cooldown_or_min_chars")
            #expect(Self.bool(metadata["persisted"]) == false)
        } else {
            Issue.record("Expected metadata object")
        }
    }

    @Test("Reason argument is forwarded to performManualCompaction")
    func reasonForwardedToPerformer() async throws {
        let conversationID = UUID()
        let stub = StubPerformer { call in
            .success(Self.successResult(conversationID: call.conversationID, trigger: call.trigger))
        }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let toolCall = Self.makeToolCall(conversationID: conversationID, reason: " switching to debugging the auth flow ")
        _ = try await provider.executeTool(toolCall)
        let calls = await stub.capturedCalls()
        #expect(calls.first?.reason == "switching to debugging the auth flow")
    }

    @Test("Empty reason argument is normalized to nil")
    func emptyReasonNormalizedToNil() async throws {
        let conversationID = UUID()
        let stub = StubPerformer { call in
            .success(Self.successResult(conversationID: call.conversationID, trigger: call.trigger))
        }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let toolCall = Self.makeToolCall(conversationID: conversationID, reason: "   ")
        _ = try await provider.executeTool(toolCall)
        let calls = await stub.capturedCalls()
        #expect(calls.first?.reason == nil)
    }

    @Test("Invalid conversation_id UUID returns ToolResult error without invoking performer")
    func invalidConversationIDIsToolErrorBeforePerformer() async throws {
        let stub = StubPerformer { _ in
            Issue.record("performer should not be called for invalid UUID")
            return .success(Self.successResult(conversationID: UUID(), trigger: .modelTool))
        }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let toolCall = Self.makeToolCall(rawConversationID: "not-a-uuid")
        let result = try await provider.executeTool(toolCall)
        #expect(!result.success)
        #expect(result.error?.contains("Invalid conversation_id") == true)
        let calls = await stub.capturedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Unknown conversation surfaces a friendly error from performer")
    func unknownConversationFromPerformerIsToolError() async throws {
        let conversationID = UUID()
        let stub = StubPerformer { _ in
            .failure(ConversationServiceError.conversationNotFound)
        }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let result = try await provider.executeTool(Self.makeToolCall(conversationID: conversationID))
        #expect(!result.success)
        #expect(result.error?.contains("Conversation not found") == true)
    }

    @Test("Other performer errors surface as ToolResult error (no rethrow)")
    func arbitraryErrorWrappedAsToolError() async throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let conversationID = UUID()
        let stub = StubPerformer { _ in .failure(Boom()) }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let result = try await provider.executeTool(Self.makeToolCall(conversationID: conversationID))
        #expect(!result.success)
        #expect(result.error?.lowercased().contains("compaction failed") == true)
    }

    @Test("Tool always uses .modelTool trigger so the 50% gate is enforced")
    func alwaysUsesModelToolTrigger() async throws {
        let conversationID = UUID()
        let stub = StubPerformer { call in
            .success(Self.successResult(conversationID: call.conversationID, trigger: call.trigger))
        }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        _ = try await provider.executeTool(Self.makeToolCall(conversationID: conversationID))
        let calls = await stub.capturedCalls()
        #expect(calls.first?.trigger == .modelTool)
    }

    @Test("availableTools advertises compact_conversation with required + optional parameters")
    func toolDefinitionShape() async {
        let stub = StubPerformer { _ in .success(Self.successResult(conversationID: UUID(), trigger: .modelTool)) }
        let provider = ContextCompactionToolProvider(performer: stub, logger: nil)
        let tools = await provider.availableTools()
        #expect(tools.count == 1)
        let def = tools[0]
        #expect(def.name == "compact_conversation")
        let convoIdParam = def.parameters.first(where: { $0.name == "conversation_id" })
        let reasonParam = def.parameters.first(where: { $0.name == "reason" })
        #expect(convoIdParam?.required == true)
        #expect(reasonParam?.required == false)
    }
}
