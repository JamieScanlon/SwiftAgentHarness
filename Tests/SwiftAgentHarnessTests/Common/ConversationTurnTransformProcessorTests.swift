import Foundation
import SwiftAgentHarness
import SwiftAgentKit
import Testing

private actor StubTurnMetadataLLM: LLMProtocol {
    private(set) var sendCount: Int = 0

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func getModelName() -> String { "stub-turn-llm" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        sendCount += 1
        return LLMResponse(
            content: #"{"summary":"Short summary","compressedText":"Compressed","tokenEstimate":123}"#,
            toolCalls: []
        )
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

@Suite("ConversationTurnTransformProcessor")
struct ConversationTurnTransformProcessorTests {
    private let processor = ConversationTurnTransformProcessor()

    private func makeMessage(
        _ role: MessageRole,
        _ content: String,
        t: TimeInterval
    ) -> Message {
        Message(
            id: UUID(),
            role: role,
            content: content,
            timestamp: Date(timeIntervalSince1970: t)
        )
    }

    @Test("non-agent mode returns no turns")
    func nonAgentModeEmpty() async throws {
        let messages = [
            Message(id: UUID(), role: .user, content: "hello"),
            Message(id: UUID(), role: .assistant, content: "world")
        ]
        let turns = processor.transform(messages: messages, interactionMode: .chat)
        #expect(turns.isEmpty)
    }

    @Test("plan mode returns no turns")
    func planModeEmpty() {
        let messages = [
            makeMessage(.user, "u1", t: 1),
            makeMessage(.assistant, "a1", t: 2)
        ]
        let turns = processor.transform(messages: messages, interactionMode: .plan)
        #expect(turns.isEmpty)
    }

    @Test("empty messages in agent mode returns empty turns")
    func emptyMessagesAgent() {
        let turns = processor.transform(messages: [], interactionMode: .agent)
        #expect(turns.isEmpty)
    }

    @Test("single user message becomes one user turn")
    func singleUserMessage() {
        let u1 = makeMessage(.user, "u1", t: 10)
        let turns = processor.transform(messages: [u1], interactionMode: .agent)
        #expect(turns.count == 1)
        #expect(turns[0].party == .user)
        #expect(turns[0].messageIDs == [u1.id])
        #expect(turns[0].createdAt == u1.timestamp)
        #expect(turns[0].updatedAt == u1.timestamp)
    }

    @Test("single assistant message becomes one assistant turn")
    func singleAssistantMessage() {
        let a1 = makeMessage(.assistant, "a1", t: 20)
        let turns = processor.transform(messages: [a1], interactionMode: .agent)
        #expect(turns.count == 1)
        #expect(turns[0].party == .assistant)
        #expect(turns[0].messageIDs == [a1.id])
    }

    @Test("single system message is ignored for turn grouping")
    func singleSystemMessage() {
        let s1 = makeMessage(.system, "sys", t: 30)
        let turns = processor.transform(messages: [s1], interactionMode: .agent)
        #expect(turns.isEmpty)
    }

    @Test("single tool message maps to assistant turn")
    func singleToolMessage() {
        let t1 = makeMessage(.tool, "tool", t: 40)
        let turns = processor.transform(messages: [t1], interactionMode: .agent)
        #expect(turns.count == 1)
        #expect(turns[0].party == .assistant)
        #expect(turns[0].messageIDs == [t1.id])
    }

    @Test("assistant tool assistant stays in one assistant turn")
    func assistantToolAssistantCollapsed() {
        let a1 = makeMessage(.assistant, "a1", t: 1)
        let t1 = makeMessage(.tool, "t1", t: 2)
        let a2 = makeMessage(.assistant, "a2", t: 3)
        let turns = processor.transform(messages: [a1, t1, a2], interactionMode: .agent)
        #expect(turns.count == 1)
        #expect(turns[0].party == .assistant)
        #expect(turns[0].messageIDs == [a1.id, t1.id, a2.id])
        #expect(turns[0].createdAt == a1.timestamp)
        #expect(turns[0].updatedAt == a2.timestamp)
    }

    @Test("back-to-back assistant messages split when first has no tool calls")
    func consecutiveAssistantsSplitWithoutToolCalls() {
        let a1 = makeMessage(.assistant, "a1", t: 1)
        let a2 = makeMessage(.assistant, "a2", t: 2)
        let turns = processor.transform(messages: [a1, a2], interactionMode: .agent)
        #expect(turns.count == 2)
        #expect(turns.map(\.party) == [.assistant, .assistant])
        #expect(turns[0].messageIDs == [a1.id])
        #expect(turns[1].messageIDs == [a2.id])
    }

    @Test("back-to-back assistant messages stay merged when first has tool calls")
    func consecutiveAssistantsStayMergedWithToolCalls() {
        let tc = ToolCall(name: "search", arguments: .object([:]), id: "tc-1")
        let a1 = Message(
            id: UUID(),
            role: .assistant,
            content: "call tool",
            timestamp: Date(timeIntervalSince1970: 1),
            toolCalls: [tc]
        )
        let a2 = makeMessage(.assistant, "a2", t: 2)
        let turns = processor.transform(messages: [a1, a2], interactionMode: .agent)
        #expect(turns.count == 1)
        #expect(turns[0].party == .assistant)
        #expect(turns[0].messageIDs == [a1.id, a2.id])
    }

    @Test("consecutive user messages are separate user turns")
    func consecutiveUsersSplit() {
        let u1 = makeMessage(.user, "u1", t: 1)
        let u2 = makeMessage(.user, "u2", t: 2)
        let u3 = makeMessage(.user, "u3", t: 3)
        let turns = processor.transform(messages: [u1, u2, u3], interactionMode: .agent)
        #expect(turns.count == 3)
        #expect(turns.allSatisfy { $0.party == .user })
        #expect(turns[0].messageIDs == [u1.id])
        #expect(turns[1].messageIDs == [u2.id])
        #expect(turns[2].messageIDs == [u3.id])
    }

    @Test("user assistant user assistant alternation creates one turn per message")
    func strictAlternation() {
        let u1 = makeMessage(.user, "u1", t: 1)
        let a1 = makeMessage(.assistant, "a1", t: 2)
        let u2 = makeMessage(.user, "u2", t: 3)
        let a2 = makeMessage(.assistant, "a2", t: 4)
        let turns = processor.transform(messages: [u1, a1, u2, a2], interactionMode: .agent)
        #expect(turns.count == 4)
        #expect(turns.map(\.party) == [.user, .assistant, .user, .assistant])
    }

    @Test("starts with assistant span then user creates assistant turn then user turn")
    func leadingAssistantSpan() {
        let a1 = makeMessage(.assistant, "a1", t: 1)
        let s1 = makeMessage(.system, "s1", t: 2)
        let t1 = makeMessage(.tool, "t1", t: 3)
        let u1 = makeMessage(.user, "u1", t: 4)
        let turns = processor.transform(messages: [a1, s1, t1, u1], interactionMode: .agent)
        #expect(turns.count == 2)
        #expect(turns[0].party == .assistant)
        #expect(turns[0].messageIDs == [a1.id, t1.id])
        #expect(turns[1].party == .user)
        #expect(turns[1].messageIDs == [u1.id])
    }

    @Test("system between user and assistant is ignored for boundaries")
    func systemAfterUserBoundary() {
        let u1 = makeMessage(.user, "u1", t: 1)
        let s1 = makeMessage(.system, "s1", t: 2)
        let a1 = makeMessage(.assistant, "a1", t: 3)
        let turns = processor.transform(messages: [u1, s1, a1], interactionMode: .agent)
        #expect(turns.count == 2)
        #expect(turns[0].party == .user)
        #expect(turns[0].messageIDs == [u1.id])
        #expect(turns[1].party == .assistant)
        #expect(turns[1].messageIDs == [a1.id])
    }

    @Test("tool between users creates assistant island turn")
    func toolBetweenUsers() {
        let u1 = makeMessage(.user, "u1", t: 1)
        let t1 = makeMessage(.tool, "t1", t: 2)
        let u2 = makeMessage(.user, "u2", t: 3)
        let turns = processor.transform(messages: [u1, t1, u2], interactionMode: .agent)
        #expect(turns.count == 3)
        #expect(turns.map(\.party) == [.user, .assistant, .user])
        #expect(turns[1].messageIDs == [t1.id])
    }

    @Test("turn metadata reuse does not alter deterministic boundaries")
    func reuseDoesNotChangeBoundaries() {
        let u1 = makeMessage(.user, "u1", t: 1)
        let a1 = makeMessage(.assistant, "a1", t: 2)
        let t1 = makeMessage(.tool, "t1", t: 3)
        let u2 = makeMessage(.user, "u2", t: 4)
        let messages = [u1, a1, t1, u2]
        var previous = processor.transform(messages: messages, interactionMode: .agent)
        let firstSig = TurnMetadataCodec.signature(for: previous[0].messageIDs)
        previous[0].metadataJSON = TurnMetadataCodec.encode(
            TurnMetadata(messageSignature: firstSig, summary: "cached")
        )

        let transformed = processor.transform(messages: messages, interactionMode: .agent, previousTurns: previous)
        #expect(transformed.map(\.party) == [.user, .assistant, .user])
        #expect(transformed.map(\.messageIDs) == [[u1.id], [a1.id, t1.id], [u2.id]])
    }

    @Test("agent mode enriches turns via LLM metadata")
    func agentModeEnrichesMetadata() async throws {
        let llm = StubTurnMetadataLLM()
        let messages = [
            Message(id: UUID(), role: .user, content: "Build feature X"),
            Message(id: UUID(), role: .assistant, content: "I will do that")
        ]

        let turns = try await processor.transform(messages: messages, interactionMode: .agent, llm: llm)
        #expect(turns.count == 2)
        #expect(turns.allSatisfy { $0.metadataJSON != nil })
        #expect(await llm.sendCount == 2)
        #expect(turns.first?.typedMetadata?.summary == "Short summary")
    }

    @Test("deterministic path reuses metadata by signature")
    func deterministicReuse() async throws {
        let messages = [
            Message(id: UUID(), role: .user, content: "u1"),
            Message(id: UUID(), role: .assistant, content: "a1")
        ]
        let signature = TurnMetadataCodec.signature(for: [messages[0].id])
        let metadata = TurnMetadata(messageSignature: signature, summary: "cached", compressedText: "c", tokenEstimate: 1)
        var previousTurns = conversationTurns(interactionMode: .agent, messages: messages)
        previousTurns[0].metadataJSON = TurnMetadataCodec.encode(metadata)

        let transformed = processor.transform(messages: messages, interactionMode: .agent, previousTurns: previousTurns)
        #expect(transformed.first?.typedMetadata?.summary == "cached")
    }

    @Test("turn metadata codec preserves originalMessageIDs linkage")
    func metadataCodecPreservesOriginalMessageIDs() {
        let id1 = UUID()
        let id2 = UUID()
        let metadata = TurnMetadata(
            messageSignature: "sig",
            summary: "s",
            compressedText: "c",
            tokenEstimate: 42,
            originalMessageIDs: [id1, id2]
        )
        let json = TurnMetadataCodec.encode(metadata)
        let decoded = TurnMetadataCodec.decode(json)
        #expect(decoded?.originalMessageIDs == [id1, id2])
    }

}
