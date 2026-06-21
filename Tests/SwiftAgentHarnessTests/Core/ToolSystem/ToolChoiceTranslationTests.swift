import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

/// Validates capability-aware ``ToolInvocationPolicy`` clamping and per-provider wire translation.
@Suite("Tool-choice translation")
struct ToolChoiceTranslationTests {

    private func config(_ policy: ToolInvocationPolicy, tools: [ToolDefinition] = []) -> LLMRequestConfig {
        LLMRequestConfig(availableTools: tools, toolInvocationPolicy: policy)
    }

    private let dummyTool = ToolDefinition(name: "think", description: "", parameters: [], type: .function)

    private func features(_ modes: Set<ToolChoiceMode>) -> ModelRequestFeatures {
        ModelRequestFeatures(
            streaming: true,
            responseFormats: [.text],
            parallelToolCalls: .unsupported,
            reasoningEfforts: [],
            toolChoiceModes: modes
        )
    }

    // MARK: - Shared resolution

    @Test("no tools always resolves to automatic")
    func emptyToolsAutomatic() {
        let effective = ToolChoiceTranslation.effectivePolicy(
            config: config(.required),
            features: features([.auto, .required]),
            hasTools: false,
            model: "m",
            logger: nil
        )
        #expect(effective == .automatic)
    }

    @Test("supported policy passes through unchanged")
    func supportedPassthrough() {
        let effective = ToolChoiceTranslation.effectivePolicy(
            config: config(.required, tools: [dummyTool]),
            features: features([.auto, .required]),
            hasTools: true,
            model: "m",
            logger: nil
        )
        #expect(effective == .required)
    }

    @Test("unsupported forced policy clamps to automatic (Ollama-style)")
    func unsupportedClamps() {
        let effective = ToolChoiceTranslation.effectivePolicy(
            config: config(.required, tools: [dummyTool]),
            features: features([.auto]),
            hasTools: true,
            model: "qwen3.6:27b",
            logger: nil
        )
        #expect(effective == .automatic)
    }

    // MARK: - OpenAI wire

    @Test("OpenAI tool_choice mapping")
    func openAIWire() {
        #expect(OpenAILLM.toolChoice(for: .automatic) == nil)
        #expect(OpenAILLM.toolChoice(for: .required) == .required)
        // `.none` collides with Optional.none in an Optional comparison context; assert by inequality instead.
        let noneChoice = OpenAILLM.toolChoice(for: .none)
        #expect(noneChoice != nil)
        #expect(noneChoice != .required)
        #expect(OpenAILLM.toolChoice(for: .specific(toolName: "finish")) == .function("finish"))
    }

    // MARK: - LM Studio wire

    @Test("LM Studio tool_choice mapping")
    func lmStudioWire() {
        #expect(LMStudioLLM.toolChoiceWire(for: .automatic) == nil)
        #expect(LMStudioLLM.toolChoiceWire(for: .required) as? String == "required")
        #expect(LMStudioLLM.toolChoiceWire(for: .none) as? String == "none")
        let specific = LMStudioLLM.toolChoiceWire(for: .specific(toolName: "finish")) as? [String: Any]
        #expect(specific?["type"] as? String == "function")
        #expect((specific?["function"] as? [String: Any])?["name"] as? String == "finish")
    }

    // MARK: - Anthropic wire

    @Test("Anthropic tool_choice mapping")
    func anthropicWire() {
        #expect(AnthropicLLM.toolChoiceWire(for: .automatic) == nil)
        #expect(AnthropicLLM.toolChoiceWire(for: .required)?["type"] as? String == "any")
        #expect(AnthropicLLM.toolChoiceWire(for: .none)?["type"] as? String == "none")
        let specific = AnthropicLLM.toolChoiceWire(for: .specific(toolName: "finish"))
        #expect(specific?["type"] as? String == "tool")
        #expect(specific?["name"] as? String == "finish")
    }
}
