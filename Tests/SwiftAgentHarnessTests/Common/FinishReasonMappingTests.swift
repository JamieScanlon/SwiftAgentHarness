import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("FinishReason mapping (per-provider raw → canonical)")
struct FinishReasonMappingTests {

    // MARK: - fromOllama

    @Test("fromOllama maps known raw values to canonical cases")
    func fromOllamaKnown() {
        #expect(FinishReason.fromOllama("stop") == .stop)
        #expect(FinishReason.fromOllama("STOP") == .stop)
        #expect(FinishReason.fromOllama("length") == .length)
        #expect(FinishReason.fromOllama("tool_calls") == .toolCalls)
        #expect(FinishReason.fromOllama("toolcalls") == .toolCalls)
        #expect(FinishReason.fromOllama("content_filter") == .contentFilter)
        #expect(FinishReason.fromOllama("error") == .error)
    }

    @Test("fromOllama maps cancel synonyms")
    func fromOllamaCancellationSynonyms() {
        #expect(FinishReason.fromOllama("cancel") == .cancelled)
        #expect(FinishReason.fromOllama("cancelled") == .cancelled)
        #expect(FinishReason.fromOllama("canceled") == .cancelled)
    }

    @Test("fromOllama returns .unknown for nil / empty / unrecognized raw")
    func fromOllamaUnknown() {
        #expect(FinishReason.fromOllama(nil) == .unknown)
        #expect(FinishReason.fromOllama("") == .unknown)
        #expect(FinishReason.fromOllama("load") == .unknown)
        #expect(FinishReason.fromOllama("custom-reason") == .unknown)
    }

    // MARK: - fromOpenAI

    @Test("fromOpenAI maps known raw values to canonical cases")
    func fromOpenAIKnown() {
        #expect(FinishReason.fromOpenAI("stop") == .stop)
        #expect(FinishReason.fromOpenAI("length") == .length)
        #expect(FinishReason.fromOpenAI("tool_calls") == .toolCalls)
        #expect(FinishReason.fromOpenAI("function_call") == .toolCalls)
        #expect(FinishReason.fromOpenAI("content_filter") == .contentFilter)
    }

    @Test("fromOpenAI returns .unknown for nil / empty / unrecognized raw")
    func fromOpenAIUnknown() {
        #expect(FinishReason.fromOpenAI(nil) == .unknown)
        #expect(FinishReason.fromOpenAI("") == .unknown)
        #expect(FinishReason.fromOpenAI("custom") == .unknown)
    }

    // MARK: - fromLMStudio

    @Test("fromLMStudio maps OpenAI-shaped raw values to canonical cases")
    func fromLMStudioKnown() {
        #expect(FinishReason.fromLMStudio("stop") == .stop)
        #expect(FinishReason.fromLMStudio("length") == .length)
        #expect(FinishReason.fromLMStudio("tool_calls") == .toolCalls)
        #expect(FinishReason.fromLMStudio("function_call") == .toolCalls)
        #expect(FinishReason.fromLMStudio("content_filter") == .contentFilter)
    }

    @Test("fromLMStudio returns .unknown for nil / empty / unrecognized raw")
    func fromLMStudioUnknown() {
        #expect(FinishReason.fromLMStudio(nil) == .unknown)
        #expect(FinishReason.fromLMStudio("") == .unknown)
        #expect(FinishReason.fromLMStudio("provider-specific") == .unknown)
    }

    // MARK: - fromAnthropic

    @Test("fromAnthropic maps known raw values to canonical cases")
    func fromAnthropicKnown() {
        #expect(FinishReason.fromAnthropic("end_turn") == .stop)
        #expect(FinishReason.fromAnthropic("stop_sequence") == .stop)
        #expect(FinishReason.fromAnthropic("max_tokens") == .length)
        #expect(FinishReason.fromAnthropic("tool_use") == .toolCalls)
        #expect(FinishReason.fromAnthropic("refusal") == .contentFilter)
    }

    @Test("fromAnthropic returns .unknown for nil / empty / unrecognized raw")
    func fromAnthropicUnknown() {
        #expect(FinishReason.fromAnthropic(nil) == .unknown)
        #expect(FinishReason.fromAnthropic("") == .unknown)
        #expect(FinishReason.fromAnthropic("custom") == .unknown)
    }

    // MARK: - rawValue stability (downstream consumers depend on these strings)

    @Test("canonical raw values match the documented vocabulary")
    func rawValueStability() {
        #expect(FinishReason.stop.rawValue == "stop")
        #expect(FinishReason.length.rawValue == "length")
        #expect(FinishReason.toolCalls.rawValue == "tool_calls")
        #expect(FinishReason.contentFilter.rawValue == "content_filter")
        #expect(FinishReason.cancelled.rawValue == "cancelled")
        #expect(FinishReason.error.rawValue == "error")
        #expect(FinishReason.unknown.rawValue == "unknown")
    }
}
