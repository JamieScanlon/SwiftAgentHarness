import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("LLMTokenMetadataBuilder")
struct LLMTokenMetadataBuilderTests {

    // MARK: - OpenAI-style remaining context

    @Test("openAIRemainingContext returns nil without model context limit")
    func openAINilWithoutLimit() {
        #expect(
            LLMTokenMetadataBuilder.openAIRemainingContext(
                modelContextLimit: nil,
                promptTokens: 100,
                reservedOutputTokens: 50
            ) == nil
        )
    }

    @Test("openAIRemainingContext returns nil without prompt tokens")
    func openAINilWithoutPrompt() {
        #expect(
            LLMTokenMetadataBuilder.openAIRemainingContext(
                modelContextLimit: 128_000,
                promptTokens: nil,
                reservedOutputTokens: 50
            ) == nil
        )
    }

    @Test("openAIRemainingContext subtracts limit, prompt, and reserved completion budget")
    func openAIBasic() {
        #expect(
            LLMTokenMetadataBuilder.openAIRemainingContext(
                modelContextLimit: 1000,
                promptTokens: 400,
                reservedOutputTokens: 100
            ) == 500
        )
    }

    @Test("openAIRemainingContext treats nil reserved as zero")
    func openAINilReservedUsesZero() {
        #expect(
            LLMTokenMetadataBuilder.openAIRemainingContext(
                modelContextLimit: 1000,
                promptTokens: 400,
                reservedOutputTokens: nil
            ) == 600
        )
    }

    @Test("openAIRemainingContext clamps to zero when over budget")
    func openAIClampsToZero() {
        #expect(
            LLMTokenMetadataBuilder.openAIRemainingContext(
                modelContextLimit: 1000,
                promptTokens: 900,
                reservedOutputTokens: 200
            ) == 0
        )
    }

    // MARK: - maxCompletionTokens from config

    @Test("maxCompletionTokens reads integer from additionalParameters")
    func maxCompletionInteger() {
        let config = LLMRequestConfig(
            additionalParameters: .object(["maxCompletionTokens": .integer(4096)])
        )
        #expect(LLMTokenMetadataBuilder.maxCompletionTokens(from: config) == 4096)
    }

    @Test("maxCompletionTokens reads double from additionalParameters")
    func maxCompletionDouble() {
        let config = LLMRequestConfig(
            additionalParameters: .object(["maxCompletionTokens": .double(8192.0)])
        )
        #expect(LLMTokenMetadataBuilder.maxCompletionTokens(from: config) == 8192)
    }

    @Test("maxCompletionTokens returns nil when absent or unsupported type")
    func maxCompletionNil() {
        #expect(LLMTokenMetadataBuilder.maxCompletionTokens(from: LLMRequestConfig()) == nil)
        let stringConfig = LLMRequestConfig(
            additionalParameters: .object(["maxCompletionTokens": .string("nope")])
        )
        #expect(LLMTokenMetadataBuilder.maxCompletionTokens(from: stringConfig) == nil)
    }

    // MARK: - build

    @Test("build maps prompt, completion, total, finishReason, and remaining in modelMetadata")
    func buildMapsFields() {
        let metadata = LLMTokenMetadataBuilder.build(
            inputTokens: 10,
            outputTokens: 20,
            remainingContextTokens: 100,
            totalTokens: 30,
            finishReason: "stop"
        )
        #expect(metadata.promptTokens == 10)
        #expect(metadata.completionTokens == 20)
        #expect(metadata.totalTokens == 30)
        #expect(metadata.finishReason == "stop")
        guard case .object(let dict) = metadata.modelMetadata else {
            Issue.record("expected modelMetadata to be a JSON object")
            return
        }
        #expect(jsonValue(dict[LLMMetadataKeys.remainingContextTokens], equalsInteger: 100))
    }

    @Test("build merges extraModelMetadata with remainingContextTokens")
    func buildMergesExtraModelMetadata() {
        let metadata = LLMTokenMetadataBuilder.build(
            inputTokens: 1,
            outputTokens: 2,
            remainingContextTokens: 3,
            totalTokens: 3,
            extraModelMetadata: .object(["custom": .string("x")]),
            finishReason: nil
        )
        guard case .object(let dict) = metadata.modelMetadata else {
            Issue.record("expected modelMetadata to be a JSON object")
            return
        }
        #expect(jsonValue(dict["custom"], equalsString: "x"))
        #expect(jsonValue(dict[LLMMetadataKeys.remainingContextTokens], equalsInteger: 3))
    }

    @Test("build omits modelMetadata when no remaining and no extra")
    func buildOmitsModelMetadataWhenEmpty() {
        let metadata = LLMTokenMetadataBuilder.build(
            inputTokens: 10,
            outputTokens: 20,
            remainingContextTokens: nil,
            totalTokens: 30,
            finishReason: nil
        )
        #expect(metadata.modelMetadata == nil)
    }

    @Test("build preserves extraModelMetadata when remainingContextTokens is nil")
    func buildPreservesExtraWithoutRemaining() {
        let metadata = LLMTokenMetadataBuilder.build(
            inputTokens: 1,
            outputTokens: 2,
            remainingContextTokens: nil,
            totalTokens: 3,
            extraModelMetadata: .object(["note": .string("only-extra")]),
            finishReason: nil
        )
        guard case .object(let dict) = metadata.modelMetadata else {
            Issue.record("expected modelMetadata object from extraModelMetadata")
            return
        }
        #expect(jsonValue(dict["note"], equalsString: "only-extra"))
        #expect(dict[LLMMetadataKeys.remainingContextTokens] == nil)
    }

    // MARK: - Documented formulas (regression anchors)

    @Test("Ollama-style remaining: num_ctx minus prompt_eval_count, floored at zero")
    func ollamaRemainingFormula() {
        let numCtx = 2048
        let promptEvalCount = 1500
        let remaining = max(0, numCtx - promptEvalCount)
        #expect(remaining == 548)
        #expect(max(0, 100 - 500) == 0)
    }
}

// MARK: - JSON test helpers (EasyJSON.JSON is not Equatable)

private func jsonValue(_ json: JSON?, equalsInteger expected: Int) -> Bool {
    guard let json, case .integer(let v) = json else { return false }
    return v == expected
}

private func jsonValue(_ json: JSON?, equalsString expected: String) -> Bool {
    guard let json, case .string(let v) = json else { return false }
    return v == expected
}
