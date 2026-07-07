import Foundation
import SwiftAgentKit
import SwiftAgentHarnessProviders
import Testing
@testable import SwiftAgentHarness

@Suite("Provider message replay", .serialized)
struct ProviderMessageReplayTests {
    @Test("transcript v4 round-trips thinking content blocks")
    func transcriptV4RoundTrip() throws {
        let message = Message(
            id: UUID(),
            role: .assistant,
            content: "answer",
            timestamp: Date(),
            toolCalls: []
        )
        let blocks: [HarnessContentBlock] = [
            .thinking(text: "hidden", signature: "sig-abc"),
            .text("answer"),
        ]
        let json = try MessageTranscriptPayloadCodec.encodePayloadJSON(
            from: message,
            contentBlocks: blocks
        )
        let payload = try MessageTranscriptPayloadCodec.decode(json)
        #expect(payload.v == MessageTranscriptPayload.currentVersion)
        #expect(payload.decodedContentBlocks().count == 2)
        let envelope = HarnessMessageEnvelope.fromTranscriptPayload(payload)
        if case .thinking(let text, let signature)? = envelope.contentBlocks.first {
            #expect(text == "hidden")
            #expect(signature == "sig-abc")
        } else {
            Issue.record("expected thinking block")
        }
    }

    @Test("anthropic signed thinking preserved for anthropic target transform")
    func anthropicPreservesSignedThinking() {
        ProviderTestManifestSupport.prepareRegistry()
        HarnessMessageEnvelopeStore.resetForTesting()
        let messageID = UUID()
        let message = Message(id: messageID, role: .assistant, content: "answer", timestamp: Date(), toolCalls: [])
        HarnessMessageEnvelopeStore.store(
            HarnessMessageEnvelope(
                message: message,
                contentBlocks: [.thinking(text: "chain", signature: "sig-1"), .text("answer")]
            )
        )
        let binding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: URL(string: "https://api.anthropic.com/v1/messages")!
        )
        let transformed = ProviderRuntimeHooks.transformMessages(
            [message],
            binding: binding,
            compat: ProviderModelCompat(thinkingFormat: "anthropic-extended-thinking")
        )
        #expect(transformed.count == 1)
        #expect(transformed[0].content.contains("chain"))
    }

    @Test("anthropic signed thinking converted for openai target transform")
    func openAIConvertsForeignThinking() {
        ProviderTestManifestSupport.prepareRegistry()
        HarnessMessageEnvelopeStore.resetForTesting()
        let messageID = UUID()
        let message = Message(id: messageID, role: .assistant, content: "answer", timestamp: Date(), toolCalls: [])
        HarnessMessageEnvelopeStore.store(
            HarnessMessageEnvelope(
                message: message,
                contentBlocks: [.thinking(text: "chain", signature: "sig-1"), .text("answer")]
            )
        )
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-4o",
            serverURL: URL(string: "https://api.openai.com/v1")!
        )
        let transformed = ProviderRuntimeHooks.transformMessages(
            [message],
            binding: binding,
            compat: ProviderModelCompat(supportsEagerToolInputStreaming: false)
        )
        #expect(transformed.count == 1)
        #expect(transformed[0].content.contains("chain"))
        #expect(!transformed[0].content.contains("sig-1"))
    }

    @Test("validateReplayTurns warns on unsigned thinking for anthropic target")
    func validateUnsignedThinking() {
        ProviderTestManifestSupport.prepareRegistry()
        HarnessMessageEnvelopeStore.resetForTesting()
        let message = Message(id: UUID(), role: .assistant, content: "answer", timestamp: Date(), toolCalls: [])
        HarnessMessageEnvelopeStore.store(
            HarnessMessageEnvelope(
                message: message,
                contentBlocks: [.thinking(text: "chain", signature: nil)]
            )
        )
        let binding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: URL(string: "https://api.anthropic.com/v1/messages")!
        )
        let issues = ProviderRuntimeHooks.validateReplayTurns(
            [message],
            binding: binding,
            compat: ProviderModelCompat(thinkingFormat: "anthropic-extended-thinking")
        )
        #expect(issues.contains { $0.code == "unsigned_thinking_dropped" })
    }

    @Test("openrouter prefers runtime resolved model metadata")
    func openRouterPrefersRuntimeResolved() {
        let binding = ProviderBinding(
            providerId: "openrouter",
            modelProtocol: .openAIAPI,
            endpointModelId: "anthropic/claude-sonnet-4-6",
            serverURL: URL(string: "https://openrouter.ai/api/v1")!
        )
        #expect(ProviderRuntimeHooks.preferRuntimeResolvedModel(binding: binding))
    }

    @Test("assistant accumulator captures reasoning into thinking blocks")
    func accumulatorReasoningBlocks() {
        var acc = AssistantMessageAccumulator()
        acc.consume(
            .stream(LLMResponse.streamChunk("", streamingFragment: .reasoning("step-by-step")))
        )
        acc.consume(.complete(LLMResponse.llmResponse(from: "done", availableTools: [])))
        let envelope = acc.finalize()
        if case .thinking(let text, nil)? = envelope.contentBlocks.first {
            #expect(text == "step-by-step")
        } else {
            Issue.record("expected thinking block from reasoning stream")
        }
    }
}
